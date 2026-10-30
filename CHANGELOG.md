# Changelog

All notable changes to `naganim` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Package identity (`naganim` / `elijahr/naganim`)**: Standardized package, module, CLI, macro, and C-ABI symbol namespaces on `naganim` (`naganim.nimble`, `src/naganim*`, `python/naganim/*`, `Naganim*`, `NAGANIM*`) for the `elijahr/naganim` repository.

### Added

- **CPython Stable ABI (`abi3` / Free-Threaded `abi3t` PEP 703/803) Direct Bindings (`src/naganim/abi.nim`, `src/naganim/abi3.nim`)**:
  - Direct `{.importc, cdecl.}` declarations for CPython Limited API symbols (`Py_IncRef`, `Py_DecRef`, `PyModuleDef_Init`, `Py_mod_gil = Py_MOD_GIL_NOT_USED`, `Py_mod_multiple_interpreters`, `PyType_FromModuleAndSpec`, `PyBuffer_FillInfo`, scalar/container/exception APIs) avoiding `<Python.h>` `#error` conflicts on Free-Threaded Python 3.13t–3.15t.
- **Runtime Lifecycle & Exception Firewall (`src/naganim/lifecycle.nim`, `src/naganim/nimony_compat.nim`)**:
  - Added idempotent `naganim_init_runtime` / `naganim_shutdown_runtime`, thread-local error reporting (`naganim_last_error`, `naganim_clear_error`), and `cAbiBoundary` / `pyAbiBoundary` exception firewalls.
- **Wait-Free Deferred `Py_DecRef` Queue & `PyObj` Wrapper (`src/naganim/gc_bridge.nim`, `src/naganim/pyobj.nim`)**:
  - Added `PyObj` with ARC/ORC lifecycle hooks (`=destroy`, `=copy`, `=sink`, `stealToPointer`, `fromStolenPointer`) and `gDeferredDecRefQueue` backed by `lockfree` `BQueue128` + overflow `TreiberStack` so non-Python worker threads safely enqueue `PyObject*` pointers for reclamation without acquiring the GIL.
- **Bidirectional Type Marshaling (`src/naganim/conversions.nim`, `src/naganim/marshal.nim`)**:
  - Implemented `toPy` and `fromPy` conversions for integers, floats, booleans, UTF-8 strings, `seq[byte]`, generic `seq[T]`, `Option[T]`, `Table[K, V]`, tuples, and `PyObj`.
- **Two-Tier PEP 3118 Zero-Copy Buffer Protocol (`src/naganim/buffer.nim`)**:
  - Added `PinnedBuffer[T]`, `ScopedSeqBuffer[T]`, PEP 3118 `Py_bf_getbuffer` / `Py_bf_releasebuffer` slot callbacks (with 32-byte `abi3t` free-threaded `PyObject` header padding, `gBufferTypeObj` dealloc lookup, and atomic `freed` CAS guard on `PinnedBufferHeader`), `toPyRaw` / `toPyMemoryView` support for `ScopedSeqBuffer[T]`, and `naganim_buf_view_t` C-ABI descriptors for zero-copy `memoryview` and `cffi` `ffi.from_buffer` sharing.
- **`{.exportpy.}` / `{.pyexport.}` Dual-Target Macros (`src/naganim/export_macro.nim`, `src/naganim/macros.nim`)**:
  - Generates both C-ABI `exportc, cdecl, dynlib` entrypoints and `abi3`/`abi3t` `PyCFunction` wrappers plus `.naganim.ir.json` metadata.
- **Lock-Free `naganim/asyncio` Completion Bridge & `AsyncChannel` (`src/naganim/asyncio.nim`, `python/naganim/asyncio.py`)**:
  - Implemented `NaganimAsyncBridge` and `NaganimAsyncChannel` combining `lockfree` `BQueue128` (`lf_bqueue128_push_ex`), `TaskPool` compute offloading, and 0-to-1 edge-triggered OS wakeup descriptors with Dekker `moSequentiallyConsistent` synchronization for `asyncio` `loop.add_reader`.
- **HeaderKit & CFFI Integration (`python/naganim/__init__.py`, `python/naganim/writer_plugin.py`, `python/naganim/_cffi_loader.py`, `python/naganim/_cli.py`)**:
  - Added `NaganimHeaderKitPlugin` and automatic CFFI / native `abi3` extension loading and `.pyi` stub generation.
