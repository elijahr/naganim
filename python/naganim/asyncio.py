"""Lock-free `naganim.asyncio` Event-Loop Bridge & `AsyncChannel` (`async for`).

Integrates Nim's `lockfree` `TaskPool` and `BQueue128` completion ring directly
with Python's `asyncio` event loop via `loop.add_reader(read_fd, ...)` with
zero polling timers (`design.md` §3.3, `CRIT-03`).
"""

from __future__ import annotations

import asyncio
import contextlib
from collections import deque
from collections.abc import Callable
from typing import Any, Self

from ._cffi_loader import NaganimCffiModule, NaganimRuntimeError


class AsyncChannel:
    """Asynchronous stream consumer (`async for`) backed by `NaganimAsyncBridge`."""

    def __init__(self, bridge: NaganimAsyncBridge, channel_id: int) -> None:
        self._bridge = bridge
        self.channel_id = channel_id
        self._items: deque[int] = deque()
        self._waiters: deque[asyncio.Future[int]] = deque()
        self._closed = False

    def _on_item(self, value: int) -> None:
        while self._waiters:
            waiter = self._waiters.popleft()
            if not waiter.done():
                waiter.set_result(value)
                return
        self._items.append(value)

    def _on_closed(self) -> None:
        self._closed = True
        while self._waiters:
            waiter = self._waiters.popleft()
            if not waiter.done():
                waiter.set_exception(StopAsyncIteration())

    def push_from_nim(self, value: int) -> None:
        self._bridge.push_channel_int(self.channel_id, value)

    def close_from_nim(self) -> None:
        self._bridge.close_channel(self.channel_id)

    def __aiter__(self) -> AsyncChannel:
        return self

    async def __anext__(self) -> int:
        if self._items:
            return self._items.popleft()
        if self._closed:
            raise StopAsyncIteration
        fut: asyncio.Future[int] = self._bridge.loop.create_future()
        self._waiters.append(fut)
        return await fut


class NaganimAsyncBridge:
    """Event-driven bridge between Python `asyncio` and Nim `lockfree` `TaskPool`."""

    def __init__(
        self,
        cffi_mod: NaganimCffiModule,
        num_workers: int = 4,
        loop: asyncio.AbstractEventLoop | None = None,
    ) -> None:
        self._mod = cffi_mod
        self._ffi = cffi_mod.ffi
        self._lib: Any = cffi_mod.lib
        self.loop = loop or asyncio.get_running_loop()
        self._bridge_ptr = self._lib.naganim_async_bridge_create(int(num_workers))
        if self._bridge_ptr == self._ffi.NULL:
            raise NaganimRuntimeError("Failed to create NaganimAsyncBridge")
        self._read_fd = int(self._lib.naganim_async_bridge_read_fd(self._bridge_ptr))
        if self._read_fd < 0:
            self._lib.naganim_async_bridge_destroy(self._bridge_ptr)
            self._bridge_ptr = self._ffi.NULL
            raise NaganimRuntimeError("Invalid read_fd from NaganimAsyncBridge")

        self._next_id = 1
        self._futures: dict[int, asyncio.Future[Any]] = {}
        self._channels: dict[int, AsyncChannel] = {}
        self._op_callbacks: dict[int, Any] = {}
        self._closed = False

        # Pre-allocate CFFI output buffers for zero-allocation completion popping
        self._out_id = self._ffi.new("uint64_t*")
        self._out_status = self._ffi.new("int*")
        self._out_int = self._ffi.new("int64_t*")
        self._out_float = self._ffi.new("double*")
        self._out_str = self._ffi.new("const char**")

        self.loop.add_reader(self._read_fd, self._on_wakeup)

    @property
    def read_fd(self) -> int:
        return self._read_fd

    def _alloc_id(self) -> int:
        cid = self._next_id
        self._next_id += 1
        return cid

    def _on_wakeup(self) -> None:
        if self._closed or self._bridge_ptr == self._ffi.NULL:
            return
        # Drain wakeup pipe AND flush deferred Py_DecRefs on the event loop thread
        self._lib.naganim_async_drain_wakeup(self._bridge_ptr)
        self._drain_completions()

    def _drain_completions(self) -> None:
        while True:
            popped = int(
                self._lib.naganim_async_pop_completion(
                    self._bridge_ptr,
                    self._out_id,
                    self._out_status,
                    self._out_int,
                    self._out_float,
                    self._out_str,
                )
            )
            if popped == 0:
                break
            fut_id = int(self._out_id[0])
            status = int(self._out_status[0])
            int_val = int(self._out_int[0])
            str_ptr = self._out_str[0]
            if str_ptr != self._ffi.NULL:
                raw_str = self._ffi.string(str_ptr)
                err_msg = (
                    raw_str.decode("utf-8", errors="replace")
                    if isinstance(raw_str, bytes)
                    else str(raw_str)
                )
            else:
                err_msg = ""

            if status in (1, 2):  # AsyncChannel event
                ch = self._channels.get(fut_id)
                if ch is not None:
                    if status == 1:
                        ch._on_item(int_val)
                    else:
                        ch._on_closed()
                continue

            fut = self._futures.pop(fut_id, None)
            if fut is not None and not fut.done():
                if status == 0:
                    fut.set_result(int_val)
                else:
                    fut.set_exception(NaganimRuntimeError(err_msg or f"Nim async task error ({status})"))

    def register_op(self, op_code: int, handler: Callable[[int, int], int] | Any) -> None:
        """Registers a native C/Nim function pointer or Python callable under `op_code` (1..255)."""
        c_fn: Any
        if isinstance(handler, self._ffi.CData):
            c_fn = handler
        elif callable(handler):
            py_fn = handler

            def _c_trampoline(
                arg_a: int,
                arg_b: int,
                out_res: Any,
                err_buf: Any,
                err_cap: int,
            ) -> int:
                try:
                    val = int(py_fn(int(arg_a), int(arg_b)))
                    if out_res != self._ffi.NULL:
                        out_res[0] = val
                    return 0
                except (RuntimeError, ValueError, TypeError, ArithmeticError, LookupError, OSError) as exc:
                    msg_bytes = f"{type(exc).__name__}: {exc}".encode("utf-8", errors="replace")
                    if err_buf != self._ffi.NULL and err_cap > 0:
                        n = min(len(msg_bytes), int(err_cap) - 1)
                        self._ffi.memmove(err_buf, msg_bytes, n)
                        err_buf[n] = b"\x00"
                    return -1

            c_fn = self._ffi.callback(
                "int(int64_t, int64_t, int64_t*, char*, size_t)",
                _c_trampoline,
            )
        else:
            raise TypeError("handler must be a CFFI function pointer or callable(arg_a, arg_b) -> int")

        rc = int(self._lib.naganim_async_register_op(int(op_code), c_fn))
        self._mod._check_status(rc)
        self._op_callbacks[int(op_code)] = c_fn

    def unregister_op(self, op_code: int) -> None:
        """Unregisters a task handler previously registered for `op_code`."""
        rc = int(self._lib.naganim_async_unregister_op(int(op_code)))
        self._mod._check_status(rc)
        self._op_callbacks.pop(int(op_code), None)

    def submit_compute(self, op_code: int, arg_a: int = 0, arg_b: int = 0) -> asyncio.Future[int]:
        """Submits a task with `op_code` and `(arg_a, arg_b)` to the Nim `TaskPool`."""
        if self._closed:
            raise NaganimRuntimeError("NaganimAsyncBridge is closed")
        fut_id = self._alloc_id()
        fut: asyncio.Future[int] = self.loop.create_future()
        self._futures[fut_id] = fut
        rc = int(
            self._lib.naganim_async_submit_compute(
                self._bridge_ptr, fut_id, int(op_code), int(arg_a), int(arg_b)
            )
        )
        if rc != 0:
            self._futures.pop(fut_id, None)
            self._mod._check_status(rc)
        return fut

    def create_channel(self) -> AsyncChannel:
        if self._closed:
            raise NaganimRuntimeError("NaganimAsyncBridge is closed")
        cid = self._alloc_id()
        ch = AsyncChannel(self, cid)
        self._channels[cid] = ch
        return ch

    def push_channel_int(self, channel_id: int, val: int) -> None:
        rc = int(self._lib.naganim_async_channel_push_int(self._bridge_ptr, int(channel_id), int(val)))
        self._mod._check_status(rc)

    def close_channel(self, channel_id: int) -> None:
        rc = int(self._lib.naganim_async_channel_close(self._bridge_ptr, int(channel_id)))
        self._mod._check_status(rc)

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            if self._read_fd >= 0:
                with contextlib.suppress(RuntimeError, ValueError, OSError):
                    self.loop.remove_reader(self._read_fd)
                self._read_fd = -1
            if self._bridge_ptr != self._ffi.NULL:
                self._lib.naganim_async_bridge_destroy(self._bridge_ptr)
                self._bridge_ptr = self._ffi.NULL
            for fut in self._futures.values():
                if not fut.done():
                    fut.cancel()
            self._futures.clear()
            for op_code in list(self._op_callbacks):
                with contextlib.suppress(Exception):
                    self._lib.naganim_async_unregister_op(int(op_code))
            self._op_callbacks.clear()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        self.close()
