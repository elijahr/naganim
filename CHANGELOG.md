# Changelog

All notable changes to `naganim` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Public Release Preparation (`README.md`, `LICENSE`, `pyproject.toml`, `.gitignore`, `docs/`)**:
  - Untracked and git-ignored `.garden/`, `garden.toml`, and `vine.toml`, added MIT `LICENSE`, completed `pyproject.toml` URLs/keywords/classifiers, expanded `README.md`, and added `docs/index.md`, `docs/architecture.md`, and `docs/api-reference.md`.
- **Experimental / Pre-Alpha Status Notice (`README.md`, `pyproject.toml`)**:
  - Added Experimental status badge and `[!WARNING]` callout in `README.md` and `Development Status :: 2 - Pre-Alpha` classifier in `pyproject.toml`.
- **Migrated `NaganimWriterPlugin` to `headerkit`'s `NimBackend` (`python/naganim/writer_plugin.py`, `python/naganim/_cli.py`)**:
  - Replaced `NimCleanupTransform` and `NimJsonDocEnricher` usage with `NimBackend.prepare_c_parse_args`, `clean_nim_c_unit`, and `DocParserTransform` (`SourceMeta` and `ParsedDoc`).

### Fixed

- **Orthogonal `NimCleanupTransform.prepare_parse()` & Unified `ChainedFilter` Pipeline (`python/naganim/writer_plugin.py`)**:
  - Updated `NaganimWriterPlugin.parse_and_clean_c_header()` to invoke `cleanup.prepare_parse(code, filename, base_inc_dirs, [])` and consolidated duplicated backend parsing (`_parse_with_headerkit_backends`) and transform chains (`_clean_and_enrich_unit` via `ChainedFilter([NimCleanupTransform(), NimJsonDocEnricher(...)])`) across `parse_and_clean_c_header()`, `to_pyi_header()`, and `to_cffi_header()`.
- **Holistic Adversarial Audit Remediations (`python/naganim/asyncio.py`, `src/naganim/asyncio.nim`, `src/naganim/abi.nim`, `python/naganim/writer_plugin.py`, `python/naganim/_cli.py`, `pyproject.toml`, `.gitignore`)**:
  - Unregistered CFFI compute callbacks in `NaganimAsyncBridge.close()` before clearing `_op_callbacks`, and released the GIL (`PyEval_SaveThread`/`PyEval_RestoreThread`) around `bridge.pool.sync()` and `bridge.pool.shutdown(wait = true)` in `destroyAsyncBridge` to prevent AB-BA GIL/TaskPool deadlocks.
  - Removed local `/Users/eek/Development/headerkit` paths from `pyproject.toml` (`[tool.uv.sources]`, `mypy_path`, `pythonpath`), prioritized `("libclang", "tree-sitter")` with explicit `RuntimeError` reporting in `NaganimWriterPlugin`, wrapped `nimcache_dir` in `tempfile.TemporaryDirectory` in `naganim build`, guarded `isFreeThreadedRuntime()` with `when sizeof(pointer) == 8`, and untracked local ceremony documents.
- **HeaderKit `>=0.51.0` Dependency & Backend C-Prototype Parsing (`pyproject.toml`, `python/naganim/writer_plugin.py`, `python/naganim/__init__.py`)**:
  - Updated `headerkit` dependency to `headerkit>=0.51.0` in `pyproject.toml` and `uv.lock`.
  - Replaced bespoke string-splitting `parse_c_type_expr` with `headerkit` backend C-prototype AST parsing (`_parse_c_function_prototypes`) and `Parameter.type_overrides` / `Function.return_type_overrides` on `NaganimWriterPlugin.to_pyi_header()`.
- **3-State Atomic `NimMain()` Spin-Latch (`[NAG-CRIT-01]`, `src/naganim/lifecycle.nim`)**:
  - Replaced the boolean `exchange(true)` guard with a 3-state atomic latch (`0 = Uninit`, `1 = Initializing`, `2 = Ready`) with `compareExchange` and `cpuRelax()` spin-waiting so concurrent threads calling `naganim_init_runtime()` cannot execute Nim code before `NimMain()` finishes.
- **Unified `PinnedBufferHeader` Lifetime & PEP 3118 Flag Compliance (`[NAG-CRIT-02 & NAG-HIGH-05]`, `src/naganim/buffer.nim`)**:
  - Unified `PinnedBufferHeader` lifetime under `refCount` (every active C-ABI or PEP 3118 export increments both `exportCount` and `refCount`; releasing an export decrements both, freeing `PinnedBufferHeader` only when `refCount.fetchSub(1, moAcquireRelease) == 1`) and eliminated the racy `hdr.freed` flag.
  - Enforced PEP 3118 `PyBUF_FORMAT`, `PyBUF_ND`, `PyBUF_STRIDES`, and `PyBUF_WRITABLE` flags in `naganimPyBufferGetBuffer` and `scopedSeqGetBufferC`.
  - Updated `naganimPyBufferDealloc` to decrement the heap type reference count (`Py_DecRef(pyTypeOf(self))`) after `PyObject_Free(self)`.
  - Replaced `GC_ref`/`GC_unref` in `ScopedSeqBuffer[T]` with shared-heap `ScopedSeqHeader[T]` atomic reference counting so cross-thread buffer release never touches thread-local ORC state (`[NAG-HIGH-09]`).
- **Free-Threaded Python (`3.13t`/`3.14t` PEP 703) `PyObj.refCount`, Borrow Guard API & Cached `Py_None` (`[NAG-CRIT-04 & NAG-HIGH-06]`, `src/naganim/abi.nim`, `src/naganim/gc_bridge.nim`)**:
  - Added runtime detection of 32-byte Free-Threaded `PyObject_FT` headers (`isFreeThreadedRuntime()`) and updated `pyRawRefCount` / `PyObj.refCount` to read `ob_ref_local + (ob_ref_shared shr 2)` on PEP 703 builds.
  - Added borrow-guard and deferred-reclamation C-ABI primitives (`naganim_enter_borrow`, `naganim_exit_borrow`, `naganim_active_borrowers`, `naganim_retire_pyobj`, `naganim_pop_deferred_decref`, `naganim_pop_deferred_decref_batch`) that suspend deferred `Py_DecRef` reclamation while any thread holds a transient borrowed `PyObject*` reference.
  - Cached the `Py_None` pointer atomically (`getCachedPyNone`) so `pyIsNone` performs a pointer comparison instead of calling `Py_BuildValue("")` on every check.
- **General-Purpose Async Compute Op Registry & Multi-Bridge Wakeup (`[NAG-HIGH-03 & NAG-HIGH-07]`, `src/naganim/asyncio.nim`, `python/naganim/asyncio.py`)**:
  - Replaced the hardcoded `op == 1` (`sum_squares`) / `op == 2` switch in `workerExecuteTask` with a general-purpose lock-free callback table (`naganim_async_register_op`, `naganim_async_unregister_op`, `bridge.register_op`, `bridge.unregister_op`) and moved sample compute ops into the test suite.
  - Replaced the single-bridge `gActiveBridgeForDecRef` pointer with a multi-bridge registry (`gActiveAsyncBridges`) and multi-hook wakeup list (`registerDeferredWakeupHook`) so multiple concurrent `NaganimAsyncBridge` instances all receive deferred-decref wakeups.
- **Extended `{.exportpy.}` Type Coverage, Thread-Local C-ABI String Ring & 3-State Module Init (`[NAG-HIGH-08 & NAG-HIGH-09]`, `src/naganim/export_macro.nim`)**:
  - Added `{.exportpy.}` support for `float`, `cint`, `uint64`, `csize_t`, `uint32`, `int32`, `uint16`, `int16`, `uint8`, `int8`, `cdouble`, and `cfloat`.
  - Replaced the single thread-local C-ABI return string buffer with a 16-slot thread-local ring (`gCAbiStringReturnRing`).
  - Converted `gModuleInitState` in `naganimInitModule` to a 3-state atomic spin-latch.
- **Full `headerkit` Integration in `writer_plugin.py` and `naganim build` CLI (`[NAG-HIGH-10]`, `python/naganim/writer_plugin.py`, `python/naganim/_cli.py`)**:
  - Rewrote `NaganimWriterPlugin` to construct and transform `headerkit.ir` AST nodes (`Header`, `Function`, `Parameter`, `Struct`, `Field`, `CType`, `Pointer`, `FunctionPointer`), run `NimCleanupTransform` and `NimJsonDocEnricher`, and emit `.pyi` and `.cdef` artifacts via registered `NaganimPyiWriter(PyiWriter)` (`"naganim-pyi"`) and `NaganimCffiWriter(CffiWriter)` (`"naganim-cffi"`).
  - Added `naganim build <nim_source>` to compile with `nim c --header:<name>.h`, parse and clean the generated header with `headerkit`, and emit `.pyi` and `.cdef` files.

### Changed

- **Package identity (`naganim`)**: Standardized package, module, CLI, macro, and C-ABI symbol namespaces on `naganim` (`naganim.nimble`, `src/naganim*`, `python/naganim/*`, `Naganim*`, `NAGANIM*`) for the `naganim` repository.

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
