# Changelog

All notable changes to `phyne` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **CPython Stable ABI (`abi3` / Free-Threaded `abi3t` PEP 703/803) Direct Bindings (`src/phyne/abi.nim`, `src/phyne/abi3.nim`)**:
  - Direct `{.importc, cdecl.}` declarations for CPython Limited API symbols (`Py_IncRef`, `Py_DecRef`, `PyModuleDef_Init`, `Py_mod_gil = Py_MOD_GIL_NOT_USED`, `Py_mod_multiple_interpreters`, `PyType_FromModuleAndSpec`, `PyBuffer_FillInfo`, scalar/container/exception APIs) avoiding `<Python.h>` `#error` conflicts on Free-Threaded Python 3.13t–3.15t.
- **Runtime Lifecycle & Exception Firewall (`src/phyne/lifecycle.nim`, `src/phyne/nimony_compat.nim`)**:
  - Added idempotent `phyne_init_runtime` / `phyne_shutdown_runtime`, thread-local error reporting (`phyne_last_error`, `phyne_clear_error`), and `cAbiBoundary` / `pyAbiBoundary` exception firewalls.
- **Wait-Free Deferred `Py_DecRef` Queue & `PyObj` Wrapper (`src/phyne/gc_bridge.nim`, `src/phyne/pyobj.nim`)**:
  - Added `PyObj` with ARC/ORC lifecycle hooks (`=destroy`, `=copy`, `=sink`, `stealToPointer`, `fromStolenPointer`) and `gDeferredDecRefQueue` backed by `lockfree` `BQueue128` + overflow `TreiberStack` so non-Python worker threads safely enqueue `PyObject*` pointers for reclamation without acquiring the GIL.
- **Bidirectional Type Marshaling (`src/phyne/conversions.nim`, `src/phyne/marshal.nim`)**:
  - Implemented `toPy` and `fromPy` conversions for integers, floats, booleans, UTF-8 strings, `seq[byte]`, generic `seq[T]`, `Option[T]`, `Table[K, V]`, tuples, and `PyObj`.
- **Two-Tier PEP 3118 Zero-Copy Buffer Protocol (`src/phyne/buffer.nim`)**:
  - Added `PinnedBuffer[T]`, `ScopedSeqBuffer[T]`, PEP 3118 `Py_bf_getbuffer` / `Py_bf_releasebuffer` slot callbacks (with 32-byte `abi3t` free-threaded `PyObject` header padding, `gBufferTypeObj` dealloc lookup, and atomic `freed` CAS guard on `PinnedBufferHeader`), `toPyRaw` / `toPyMemoryView` support for `ScopedSeqBuffer[T]`, and `phyne_buf_view_t` C-ABI descriptors for zero-copy `memoryview` and `cffi` `ffi.from_buffer` sharing.
- **`{.exportpy.}` / `{.pyexport.}` Dual-Target Macros (`src/phyne/export_macro.nim`, `src/phyne/macros.nim`)**:
  - Generates both C-ABI `exportc, cdecl, dynlib` entrypoints and `abi3`/`abi3t` `PyCFunction` wrappers plus `.phyne.ir.json` metadata.
- **Lock-Free `phyne/asyncio` Completion Bridge & `AsyncChannel` (`src/phyne/asyncio.nim`, `python/phyne/asyncio.py`)**:
  - Implemented `PhyneAsyncBridge` and `PhyneAsyncChannel` combining `lockfree` `BQueue128` (`lf_bqueue128_push_ex`), `TaskPool` compute offloading, and 0-to-1 edge-triggered OS wakeup descriptors with Dekker `moSequentiallyConsistent` synchronization for `asyncio` `loop.add_reader`.
- **HeaderKit & CFFI Integration (`python/phyne/__init__.py`, `python/phyne/writer_plugin.py`, `python/phyne/_cffi_loader.py`, `python/phyne/_cli.py`)**:
  - Added `PhyneHeaderKitPlugin` and automatic CFFI / native `abi3` extension loading and `.pyi` stub generation.
