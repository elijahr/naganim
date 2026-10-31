"""CFFI & ABI3 Dynamic Extension Loaders for naganim."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import weakref
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any, Self

import cffi

from .writer_plugin import NaganimFunctionSpec, NaganimModuleIr, NaganimWriterPlugin


class NaganimRuntimeError(RuntimeError):
    """Raised when a Nim procedure exported via naganim C-ABI fails with an exception."""


def _decode_cffi_str(raw: bytes | str) -> str:
    return raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw


class NaganimBufferOwner:
    """RAII wrapper for `naganim_buf_view_t` exported over CFFI."""

    def __init__(self, ffi: cffi.FFI, lib: Any, view_ptr: Any) -> None:
        self._ffi = ffi
        self._lib = lib
        self._view_ptr = view_ptr
        self._released = False
        self._finalizer = weakref.finalize(self, lib.naganim_buf_release, view_ptr)

    @property
    def byte_length(self) -> int:
        return int(self._view_ptr.len)

    @property
    def readonly(self) -> bool:
        return bool(self._view_ptr.readonly)

    def to_buffer(self) -> Any:
        if self._released:
            raise BufferError("NaganimBufferOwner has already been released")
        return self._ffi.buffer(self._view_ptr.data, int(self._view_ptr.len))

    def release(self) -> None:
        if not self._released:
            self._released = True
            self._finalizer()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        self.release()


class NaganimCffiModule:
    """Dynamically wraps a compiled `naganim` shared library via CFFI ABI mode."""

    def __init__(
        self,
        lib_path: str | Path,
        *,
        c_header_path: str | Path | None = None,
        nim_source_path: str | Path | None = None,
    ) -> None:
        self.lib_path = Path(lib_path).resolve()
        if not self.lib_path.exists():
            raise FileNotFoundError(f"Shared library not found: {self.lib_path}")

        # Bootstrap FFI to read embedded IR JSON
        boot_ffi = cffi.FFI()
        boot_ffi.cdef(NaganimWriterPlugin.BASE_CFFI_CDEF)
        boot_lib: Any = boot_ffi.dlopen(str(self.lib_path))
        rc = int(boot_lib.naganim_init_runtime())
        if rc != 0:
            raise NaganimRuntimeError(f"naganim_init_runtime() failed with status {rc}")

        ir_ptr = boot_lib.naganim_module_ir_json()
        if ir_ptr == boot_ffi.NULL:
            raise NaganimRuntimeError("naganim_module_ir_json() returned NULL")
        ir_json = _decode_cffi_str(boot_ffi.string(ir_ptr))
        self.ir: NaganimModuleIr = NaganimModuleIr.from_json(ir_json)
        self.plugin = NaganimWriterPlugin(
            self.ir,
            c_header_path=c_header_path,
            nim_source_path=nim_source_path,
        )

        # Full FFI instance with all exported C-ABI function signatures
        self.ffi = cffi.FFI()
        self.ffi.cdef(self.plugin.generate_cffi_cdef())
        self.lib: Any = self.ffi.dlopen(str(self.lib_path))
        self._functions: dict[str, Callable[..., Any]] = {}

        for fn_spec in self.ir.functions:
            if fn_spec.has_c_abi:
                wrapper = self._make_c_wrapper(fn_spec)
                self._functions[fn_spec.name] = wrapper
                setattr(self, fn_spec.name, wrapper)

    def _check_status(self, status: int) -> None:
        if status != 0:
            err_ptr = self.lib.naganim_last_error()
            if err_ptr != self.ffi.NULL:
                msg = _decode_cffi_str(self.ffi.string(err_ptr))
            else:
                msg = f"Nim C-ABI error (status={status})"
            self.lib.naganim_clear_error()
            raise NaganimRuntimeError(msg)

    def _make_c_wrapper(self, spec: NaganimFunctionSpec) -> Callable[..., Any]:
        c_fn = getattr(self.lib, spec.c_symbol)
        ret_c = spec.return_c_type
        ret_nim = spec.return_nim_type
        params = spec.params

        def _call(*args: Any) -> Any:
            if len(args) != len(params):
                raise TypeError(
                    f"{spec.name}() takes exactly {len(params)} argument(s) ({len(args)} given)"
                )
            converted_args: list[Any] = []
            keepalive: list[Any] = []
            for val, p_spec in zip(args, params):
                if p_spec.c_type == "const char*":
                    if not isinstance(val, str):
                        raise TypeError(
                            f"Argument '{p_spec.name}' to {spec.name}() must be str, got {type(val).__name__}"
                        )
                    encoded = val.encode("utf-8")
                    c_buf = self.ffi.new("char[]", encoded)
                    keepalive.append(c_buf)
                    converted_args.append(c_buf)
                elif p_spec.c_type == "bool":
                    if not isinstance(val, bool):
                        raise TypeError(
                            f"Argument '{p_spec.name}' to {spec.name}() must be bool, got {type(val).__name__}"
                        )
                    converted_args.append(bool(val))
                elif p_spec.c_type in ("double", "float"):
                    if isinstance(val, bool) or not isinstance(val, (int, float)):
                        raise TypeError(
                            f"Argument '{p_spec.name}' to {spec.name}() must be float, got {type(val).__name__}"
                        )
                    converted_args.append(float(val))
                else:
                    if isinstance(val, bool) or not isinstance(val, int):
                        raise TypeError(
                            f"Argument '{p_spec.name}' to {spec.name}() must be int, got {type(val).__name__}"
                        )
                    converted_args.append(int(val))

            if ret_nim == "void" or ret_c == "void":
                status = int(c_fn(*converted_args))
                self._check_status(status)
                return None
            elif ret_c == "const char*":
                out_ptr = self.ffi.new("const char**")
                status = int(c_fn(*converted_args, out_ptr))
                self._check_status(status)
                if out_ptr[0] == self.ffi.NULL:
                    return ""
                return _decode_cffi_str(self.ffi.string(out_ptr[0]))
            elif ret_c == "naganim_buf_view_t":
                out_view = self.ffi.new("naganim_buf_view_t*")
                status = int(c_fn(*converted_args, out_view))
                self._check_status(status)
                return NaganimBufferOwner(self.ffi, self.lib, out_view)
            elif ret_c == "bool":
                out_ptr = self.ffi.new("bool*")
                status = int(c_fn(*converted_args, out_ptr))
                self._check_status(status)
                return bool(out_ptr[0])
            elif ret_c in ("double", "float"):
                out_ptr = self.ffi.new(f"{ret_c}*")
                status = int(c_fn(*converted_args, out_ptr))
                self._check_status(status)
                return float(out_ptr[0])
            else:
                out_ptr = self.ffi.new(f"{ret_c}*")
                status = int(c_fn(*converted_args, out_ptr))
                self._check_status(status)
                return int(out_ptr[0])

        _call.__name__ = spec.name
        _call.__doc__ = spec.doc
        return _call

    def flush_deferred_decrefs(self) -> int:
        return int(self.lib.naganim_flush_deferred_decrefs())

    def deferred_decref_count(self) -> int:
        return int(self.lib.naganim_deferred_decref_count())

    def enter_borrow(self) -> int:
        return int(self.lib.naganim_enter_borrow())

    def exit_borrow(self) -> int:
        return int(self.lib.naganim_exit_borrow())

    def active_borrowers(self) -> int:
        return int(self.lib.naganim_active_borrowers())

    def retire_pyobj(self, ptr_addr: int) -> bool:
        return bool(self.lib.naganim_retire_pyobj(self.ffi.cast("void*", ptr_addr)))

    def pop_deferred_decref(self) -> int:
        out = self.ffi.new("void**")
        if bool(self.lib.naganim_pop_deferred_decref(out)):
            return int(self.ffi.cast("uintptr_t", out[0]))
        return 0

    def pop_deferred_decref_batch(self, max_items: int) -> list[int]:
        if max_items <= 0:
            return []
        buf = self.ffi.new("void*[]", max_items)
        popped = int(self.lib.naganim_pop_deferred_decref_batch(buf, max_items))
        return [int(self.ffi.cast("uintptr_t", buf[i])) for i in range(popped)]


def load_cffi_library(
    lib_path: str | Path,
    *,
    c_header_path: str | Path | None = None,
    nim_source_path: str | Path | None = None,
) -> NaganimCffiModule:
    """Loads a compiled `naganim` shared library via CFFI ABI mode."""
    return NaganimCffiModule(
        lib_path,
        c_header_path=c_header_path,
        nim_source_path=nim_source_path,
    )


def load_abi3_extension(module_name: str, lib_path: str | Path) -> ModuleType:
    """Loads a compiled `naganim` shared library as a native CPython PEP 489 `abi3`/`abi3t` extension."""
    resolved = Path(lib_path).resolve()
    if not resolved.exists():
        raise FileNotFoundError(f"Extension library not found: {resolved}")
    loader = importlib.machinery.ExtensionFileLoader(module_name, str(resolved))
    spec = importlib.util.spec_from_loader(module_name, loader)
    if spec is None:
        raise ImportError(f"Could not create ExtensionFileLoader spec for {module_name} at {resolved}")
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod
