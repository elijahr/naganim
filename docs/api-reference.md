# `naganim` API Reference

> [!WARNING]
> **Experimental / Pre-Alpha Software — Not Ready for Production**
> This project is an active research and development prototype. APIs, ABI layouts, and wire formats are unstable and subject to breaking changes without notice. Do not use in production systems.

Complete reference for both the **Nim** (`src/naganim*`) and **Python** (`python/naganim*`) APIs.

---

## Part 1: Nim API Reference

Import the umbrella module to access all `naganim` Nim primitives:

```nim
import naganim
```

### 1.1 `naganim/export_macro` — Dual-Target Export Macros & Module Init

#### Macros & Templates

- **`macro exportpy*(procDef: untyped): untyped`** (alias: **`macro pyexport*(procDef: untyped): untyped`**)
  Wraps a Nim `proc` and generates:
  1. `naganim_py_<name>(self, args: PyObjectPtr): PyObjectPtr {.cdecl.}` — CPython `abi3`/`abi3t` `PyCFunction` wrapper guarded by `pyAbiBoundary`.
  2. `naganim_c_<name>(..., outResult: ptr CType): cint {.exportc, cdecl, dynlib.}` — C-ABI entrypoint guarded by `cAbiBoundary` (emitted for C-ABI-compatible parameter/return types).
  3. Compile-time registration in `gRegisteredMethods` and `gRegisteredIr`.

  **Supported `{.exportpy.}` Parameter & Return Types**:
  - Integers: `int`, `int64`, `int32`, `int16`, `int8`, `cint`, `uint`, `uint64`, `uint32`, `uint16`, `uint8`, `csize_t`
  - Floats: `float`, `float64`, `float32`, `cdouble`, `cfloat`
  - Booleans & Strings: `bool`, `string`, `cstring`
  - Containers (`abi3`/`abi3t` target): `seq[byte]`, `seq[T]`, `Option[T]`, `Table[K, V]`, `tuple`
  - Zero-Copy Buffers: `PinnedBuffer[T]` (exported to Python as `memoryview` and to CFFI as `naganim_buf_view_t`), `ScopedSeqBuffer[T]`
  - Raw Handles: `PyObj`, `PyObjectPtr`

- **`template naganimInitModule*(moduleNameLit: static[string])`**
  Generates:
  - `naganim_module_ir_json*(): cstring {.exportc, cdecl, dynlib.}` returning the embedded JSON IR for the module.
  - `PyInit_<moduleName>*(): PyObjectPtr {.exportc, cdecl, dynlib.}` initializing the PEP 489 multi-phase `PyModuleDef` / `PyModuleDef_FT` with `Py_mod_gil = Py_MOD_GIL_NOT_USED` and `Py_mod_multiple_interpreters = Py_MOD_PER_INTERPRETER_GIL_SUPPORTED`.

#### IR Metadata Types

```nim
type
  NaganimParamIr* = object
    name*: string
    nimType*: string
    cType*: string
    pyType*: string

  NaganimProcIr* = object
    name*: string
    cSymbol*: string
    pySymbol*: string
    doc*: string
    params*: seq[NaganimParamIr]
    returnNimType*: string
    returnCType*: string
    returnPyType*: string
    hasCAbi*: bool
```

---

### 1.2 `naganim/buffer` — Zero-Copy PEP 3118 & CFFI Buffers

#### Types

- **`PinnedBuffer*[T]`**: Shared-heap zero-copy buffer with unified atomic `refCount` and `exportCount`.
- **`ScopedSeqBuffer*[T]`**: Shared-heap wrapper around a `seq[T]` that guards against resize/mutation while exported to Python.
- **`naganim_buf_view_t*`**: C-ABI struct (`data`, `len`, `itemsize`, `readonly`, `ndim`, `format`, `owner_ctx`, `release_fn`) for zero-copy CFFI buffer sharing.

#### `PinnedBuffer[T]` Procedures

- **`proc newPinnedBuffer*[T](length: int, readonly: bool = false): PinnedBuffer[T]`**
  Allocates a zero-initialized `PinnedBuffer[T]` of `length` elements on the shared heap.
- **`proc newPinnedBufferFromSlice*[T](slice: openArray[T], readonly: bool = false): PinnedBuffer[T]`**
  Allocates a `PinnedBuffer[T]` and copies `slice` into it.
- **`proc len*[T](buf: PinnedBuffer[T]): int`** — Element count.
- **`proc byteLen*[T](buf: PinnedBuffer[T]): int`** — Total byte length (`len * sizeof(T)`).
- **`proc dataPtr*[T](buf: PinnedBuffer[T]): ptr UncheckedArray[T]`** — Raw pointer to elements.
- **`template dataOpenArray*[T](buf: PinnedBuffer[T]): openArray[T]`** — Zero-copy `openArray[T]` view.
- **`proc exportCount*[T](buf: PinnedBuffer[T]): int`** — Number of active Python/CFFI views.
- **`proc refCount*[T](buf: PinnedBuffer[T]): int`** — Total atomic reference count.
- **`proc exportCAbiView*[T](buf: PinnedBuffer[T], outView: ptr naganim_buf_view_t): cint`** — Populates `outView` and increments `exportCount` and `refCount`.
- **`proc toPyMemoryView*[T](buf: PinnedBuffer[T]): PyObjectPtr`** — Wraps `buf` in a PEP 3118 heap object and returns `PyMemoryView_FromObject`.

#### `ScopedSeqBuffer[T]` Procedures

- **`proc newScopedSeqBuffer*[T](initial: sink seq[T], readonly: bool = false): ScopedSeqBuffer[T]`**
- **`proc len*[T](buf: ScopedSeqBuffer[T]): int`**
- **`proc exportCount*[T](buf: ScopedSeqBuffer[T]): int`**
- **`proc isExported*[T](buf: ScopedSeqBuffer[T]): bool`**
- **`proc mutateAdd*[T](buf: var ScopedSeqBuffer[T], item: sink T)`** — Appends `item`, or raises `BufferExportedDefect` if `exportCount > 0`.
- **`proc mutateSetLen*[T](buf: var ScopedSeqBuffer[T], newLen: int)`** — Resizes the underlying `seq[T]`, or raises `BufferExportedDefect` if `exportCount > 0`.
- **`proc toPyMemoryView*[T](buf: var ScopedSeqBuffer[T]): PyObjectPtr`** — Returns a PEP 3118 `memoryview` backed by the `ScopedSeqBuffer[T]`.

#### C-ABI Buffer Release

- **`proc naganim_buf_release*(view: ptr naganim_buf_view_t) {.exportc, cdecl, dynlib.}`** — Invokes `view.release_fn(view.owner_ctx)` and clears `view.data`.

---

### 1.3 `naganim/gc_bridge` — `PyObj` & Deferred `Py_DecRef` Queue

#### Types & Constructors

- **`PyObj* = object`**: ORC-managed wrapper around `PyObjectPtr` (`raw*: PyObjectPtr`).
- **`proc fromStolenPointer*(p: pointer): PyObj`** — Adopts an existing owned `PyObject*` reference without calling `Py_IncRef`.
- **`proc fromBorrowedPointer*(p: pointer): PyObj`** — Calls `Py_IncRef` (when `PyGILState_Check() == 1`) and wraps `p`.
- **`proc stealToPointer*(obj: sink PyObj): pointer`** — Extracts `obj.raw` and zeroes `obj.raw` so `=destroy` is a no-op (used to transfer ownership into worker closures).
- **`proc isNil*(obj: PyObj): bool`**
- **`proc refCount*(obj: PyObj): int`** — Reads the object's reference count (supporting both standard `PyObject` and 32-byte Free-Threaded `PyObject_FT`).

#### Deferred `Py_DecRef` & Borrow Guards

- **`proc enqueueDeferredDecRef*(raw: PyObjectPtr)`** — Enqueues `raw` onto the wait-free `BQueue128` / `TreiberStack` retirement queue.
- **`proc flushDeferredDecRefs*(): int`** — Drains queued pointers and calls `Py_DecRef` when `PyGILState_Check() == 1` and `activeBorrowers() == 0`.
- **`proc pendingDeferredDecRefs*(): int`** — Number of pointers waiting for reclamation.
- **`proc enterBorrow*()` / `proc exitBorrow*()` / `proc activeBorrowers*(): int`** — Cross-thread reader borrow guards.
- **Exported C-ABI Functions**:
  - `naganim_enter_borrow*(): cint`
  - `naganim_exit_borrow*(): cint`
  - `naganim_active_borrowers*(): cint`
  - `naganim_retire_pyobj*(rawObj: pointer): cint`
  - `naganim_pop_deferred_decref*(): pointer`
  - `naganim_pop_deferred_decref_batch*(outBuf: ptr pointer, maxCount: cint): cint`
  - `naganim_flush_deferred_decrefs*(): cint`
  - `naganim_pending_deferred_decrefs*(): cint`

---

### 1.4 `naganim/conversions` — Bidirectional Type Marshaling

- **`proc toPy*[T](val: T): PyObj`** / **`proc toPyRaw*[T](val: T): PyObjectPtr`**
  Converts a Nim value (`bool`, signed/unsigned integers, floats, `string`, `cstring`, `seq[byte]`, `seq[T]`, `Option[T]`, `Table[K, V]`, `tuple`, `PinnedBuffer[T]`, `ScopedSeqBuffer[T]`, `PyObj`, `PyObjectPtr`) into a new Python object reference.
- **`proc fromPy*[T](obj: PyObj, target: typedesc[T]): T`** / **`proc fromPyRaw*[T](obj: PyObjectPtr, target: typedesc[T]): T`**
  Converts a Python object into the target Nim type `T` or raises `NaganimConversionError`.

---

### 1.5 `naganim/lifecycle` — Runtime Initialization & Error Firewalls

- **Exception Types**: `NaganimError`, `NaganimConversionError`, `NaganimPythonError`, `BufferExportedDefect`.
- **`proc naganim_init_runtime*(): cint {.exportc, cdecl, dynlib.}`** — Idempotent 3-state atomic `NimMain()` initialization.
- **`proc naganim_shutdown_runtime*(): cint {.exportc, cdecl, dynlib.}`** — Flushes deferred decrefs and decrements runtime refcount.
- **`proc naganim_last_error*(): cstring {.exportc, cdecl, dynlib.}`** — Returns the thread-local error message from the last failed C-ABI call, or `nil`.
- **`proc naganim_clear_error*() {.exportc, cdecl, dynlib.}`** — Clears the thread-local error state.
- **`template cAbiBoundary*(body: untyped): cint`** — Catches Nim exceptions/defects at the C-ABI boundary and returns `0` (success) or `-1` (error).
- **`template pyAbiBoundary*(body: untyped): PyObjectPtr`** — Catches Nim exceptions/defects at the `PyCFunction` boundary, sets the appropriate Python exception (`TypeError`, `BufferError`, `RuntimeError`), and returns `nil`.

---

### 1.6 `naganim/asyncio` — Native `TaskPool` & Event-Loop Wakeup Bridge

- **`proc createAsyncBridge*(numWorkers: int = 4): ptr NaganimAsyncBridge`** (`naganim_async_bridge_create`)
- **`proc destroyAsyncBridge*(bridge: ptr NaganimAsyncBridge)`** (`naganim_async_bridge_destroy`)
- **`proc readFd*(bridge: ptr NaganimAsyncBridge): cint`** (`naganim_async_bridge_read_fd`)
- **`proc registerComputeOp*(opCode: cint, cb: NaganimComputeOpProc): cint`** (`naganim_async_register_op`)
- **`proc unregisterComputeOp*(opCode: cint): cint`** (`naganim_async_unregister_op`)
- **`proc submitComputeTask*(bridge: ptr NaganimAsyncBridge, futureId: uint64, opCode: cint, argA: int64, argB: int64, pyObjCarry: pointer = nil): cint`** (`naganim_async_submit_compute`)
- **`proc pushChannelInt*(bridge: ptr NaganimAsyncBridge, channelId: uint64, val: int64): cint`** (`naganim_async_channel_push_int`)
- **`proc closeChannel*(bridge: ptr NaganimAsyncBridge, channelId: uint64): cint`** (`naganim_async_channel_close`)

---

## Part 2: Python API Reference

```python
import naganim
```

### 2.1 Dynamic Extension Loaders (`naganim._cffi_loader`)

- **`load_abi3_extension(module_name: str, lib_path: str | Path) -> ModuleType`**
  Loads a compiled `naganim` shared library as a native CPython `abi3` / `abi3t` extension module via `ExtensionFileLoader` and `PyInit_<module_name>`.
- **`load_cffi_library(lib_path: str | Path, *, c_header_path: str | Path | None = None, nim_source_path: str | Path | None = None) -> NaganimCffiModule`**
  Loads a compiled `naganim` shared library via CFFI ABI mode, initializes the Nim runtime (`naganim_init_runtime()`), extracts embedded `.naganim.ir.json` metadata (`naganim_module_ir_json()`), generates CFFI `cdef` declarations via `NaganimWriterPlugin`, and attaches Python wrapper methods for every exported C-ABI function.
- **`class NaganimCffiModule`**:
  - `.lib_path: Path` — Resolved path to the shared library.
  - `.ir: NaganimModuleIr` — Parsed embedded module IR.
  - `.plugin: NaganimWriterPlugin` — Associated HeaderKit writer plugin.
  - `.generate_pyi() -> str` — Generates PEP 484 `.pyi` stub source for the module.
  - `.flush_deferred_decrefs() -> int` — Flushes pending deferred `Py_DecRef` pointers.
  - `.pending_deferred_decrefs() -> int` — Returns count of pending deferred `Py_DecRef` pointers.
  - `.close() -> None` — Shuts down the runtime (`naganim_shutdown_runtime()`).
- **`class NaganimBufferOwner`**:
  Context manager wrapping a `naganim_buf_view_t*` returned over CFFI:
  - `.byte_length: int`
  - `.readonly: bool`
  - `.to_buffer() -> cffi.FFI.buffer`
  - `.release() -> None`
- **`class NaganimRuntimeError(RuntimeError)`**:
  Raised when an exported Nim C-ABI function returns a non-zero status code.

---

### 2.2 Asyncio Bridge (`naganim.asyncio`)

- **`class NaganimAsyncBridge(cffi_mod: NaganimCffiModule, num_workers: int = 4, loop: asyncio.AbstractEventLoop | None = None)`**:
  - `.read_fd: int` — Non-blocking OS pipe read descriptor monitored via `loop.add_reader`.
  - `.register_op(op_code: int, fn: Callable[[int, int], int]) -> None` — Registers a CFFI callback for `op_code` (`0 <= op_code < 256`).
  - `.unregister_op(op_code: int) -> None` — Unregisters `op_code`.
  - `async .submit_compute(op_code: int, arg_a: int, arg_b: int = 0) -> int` — Submits a compute task to the Nim `TaskPool` and awaits completion without polling.
  - `.create_channel(channel_id: int) -> AsyncChannel` — Creates an `AsyncChannel` bound to `channel_id`.
  - `.push_channel_int(channel_id: int, value: int) -> None` — Pushes an integer to `channel_id` from Nim/CFFI.
  - `.close_channel(channel_id: int) -> None` — Marks `channel_id` closed.
  - `.close() -> None` — Removes the event-loop reader, unregisters callbacks, and destroys the native bridge.
- **`class AsyncChannel`**:
  Implements `AsyncIterator[int]` (`async for value in channel:`), `.push_from_nim(value: int)`, and `.close_from_nim()`.

---

### 2.3 HeaderKit Writer Plugin (`naganim.writer_plugin`)

- **`class NaganimWriterPlugin(module_ir: NaganimModuleIr, *, c_header_path: str | Path | None = None, nim_source_path: str | Path | None = None, include_dirs: list[str] | None = None)`**:
  - `.parse_and_clean_c_header() -> SourceUnit | None` — Parses the `nim c --header` C file via `headerkit` using `NimBackend.prepare_c_parse_args`, `clean_nim_c_unit`, and `DocParserTransform`.
  - `.to_pyi_header() -> SourceUnit` — Builds the `headerkit.ir.SourceUnit` with Python type overrides (`Parameter.type_overrides`, `Function.return_type_overrides`, `ParsedDoc`).
  - `.to_cffi_header() -> SourceUnit` — Builds the C-ABI `SourceUnit` for `CffiWriter`.
  - `.generate_pyi() -> str` — Renders the `.pyi` stub via `NaganimPyiWriter` (`"naganim-pyi"`).
  - `.generate_cffi_cdef() -> str` — Renders the CFFI `cdef` string via `NaganimCffiWriter` (`"naganim-cffi"`).
  - `.write_pyi(output_path: str | Path) -> Path`
  - `.write_cffi_cdef(output_path: str | Path) -> Path`

---

### 2.4 CLI (`naganim`)

```bash
# Compile a .nim extension and emit shared library + .pyi + .cdef
naganim build <nim_source> [--out-dir DIR] [--out-lib PATH] [--out-pyi PATH] [--out-cdef PATH] [--header NAME] [--nim-path DIR]

# Generate .pyi and/or .cdef from an already compiled naganim shared library
naganim stub <lib_path> [--c-header PATH] [--nim-source PATH] [--out-pyi PATH] [--out-cdef PATH]
```
