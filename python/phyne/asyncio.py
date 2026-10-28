"""Lock-free `phyne.asyncio` Event-Loop Bridge & `AsyncChannel` (`async for`).

Integrates Nim's `lockfree` `TaskPool` and `BQueue128` completion ring directly
with Python's `asyncio` event loop via `loop.add_reader(read_fd, ...)` with
zero polling timers (`design.md` §3.3, `CRIT-03`).
"""

from __future__ import annotations

import asyncio
from collections import deque
from typing import Any

from ._cffi_loader import PhyneCffiModule, PhyneRuntimeError


class AsyncChannel:
    """Asynchronous stream consumer (`async for`) backed by `PhyneAsyncBridge`."""

    def __init__(self, bridge: PhyneAsyncBridge, channel_id: int) -> None:
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


class PhyneAsyncBridge:
    """Event-driven bridge between Python `asyncio` and Nim `lockfree` `TaskPool`."""

    def __init__(
        self,
        cffi_mod: PhyneCffiModule,
        num_workers: int = 4,
        loop: asyncio.AbstractEventLoop | None = None,
    ) -> None:
        self._mod = cffi_mod
        self._ffi = cffi_mod.ffi
        self._lib = cffi_mod.lib
        self.loop = loop or asyncio.get_running_loop()
        self._bridge_ptr = self._lib.phyne_async_bridge_create(int(num_workers))
        if self._bridge_ptr == self._ffi.NULL:
            raise PhyneRuntimeError("Failed to create PhyneAsyncBridge")
        self._read_fd = int(self._lib.phyne_async_bridge_read_fd(self._bridge_ptr))
        if self._read_fd < 0:
            self._lib.phyne_async_bridge_destroy(self._bridge_ptr)
            self._bridge_ptr = self._ffi.NULL
            raise PhyneRuntimeError("Invalid read_fd from PhyneAsyncBridge")

        self._next_id = 1
        self._futures: dict[int, asyncio.Future[Any]] = {}
        self._channels: dict[int, AsyncChannel] = {}
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
        self._lib.phyne_async_drain_wakeup(self._bridge_ptr)
        self._drain_completions()

    def _drain_completions(self) -> None:
        while True:
            popped = int(
                self._lib.phyne_async_pop_completion(
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
            err_msg = (
                self._ffi.string(str_ptr).decode("utf-8", errors="replace")
                if str_ptr != self._ffi.NULL
                else ""
            )

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
                    fut.set_exception(PhyneRuntimeError(err_msg or f"Nim async task error ({status})"))

    def submit_compute(self, op_code: int, arg_a: int, arg_b: int) -> asyncio.Future[int]:
        if self._closed:
            raise PhyneRuntimeError("PhyneAsyncBridge is closed")
        fut_id = self._alloc_id()
        fut: asyncio.Future[int] = self.loop.create_future()
        self._futures[fut_id] = fut
        rc = int(
            self._lib.phyne_async_submit_compute(
                self._bridge_ptr, fut_id, int(op_code), int(arg_a), int(arg_b)
            )
        )
        if rc != 0:
            self._futures.pop(fut_id, None)
            self._mod._check_status(rc)
        return fut

    def sum_squares(self, start: int, end: int) -> asyncio.Future[int]:
        """Offloads parallel sum-of-squares computation `[start..end]` to Nim `TaskPool`."""
        return self.submit_compute(1, start, end)

    def create_channel(self) -> AsyncChannel:
        if self._closed:
            raise PhyneRuntimeError("PhyneAsyncBridge is closed")
        cid = self._alloc_id()
        ch = AsyncChannel(self, cid)
        self._channels[cid] = ch
        return ch

    def push_channel_int(self, channel_id: int, val: int) -> None:
        rc = int(self._lib.phyne_async_channel_push_int(self._bridge_ptr, int(channel_id), int(val)))
        self._mod._check_status(rc)

    def close_channel(self, channel_id: int) -> None:
        rc = int(self._lib.phyne_async_channel_close(self._bridge_ptr, int(channel_id)))
        self._mod._check_status(rc)

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            if self._read_fd >= 0:
                try:
                    self.loop.remove_reader(self._read_fd)
                except Exception:
                    pass
                self._read_fd = -1
            if self._bridge_ptr != self._ffi.NULL:
                self._lib.phyne_async_bridge_destroy(self._bridge_ptr)
                self._bridge_ptr = self._ffi.NULL
            for fut in self._futures.values():
                if not fut.done():
                    fut.cancel()
            self._futures.clear()

    async def __aenter__(self) -> PhyneAsyncBridge:
        return self

    async def __aexit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.close()
