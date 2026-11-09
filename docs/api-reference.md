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

- **`macro exportpy*(procDef: untyped): untyped`** (alias: **`template pyexport*(procDef: untyped): untyped`**)
  Wraps a Nim `proc` or `func` and generates:
  1. `naganim_py_<name>*(self: PyObjectPtr, args: PyObjectPtr): PyObjectPtr {.exportc, cdecl, dynlib, gcsafe, raises: [].}` — CPython `abi3`/`abi3t` `PyCFunction` wrapper guarded by `pyAbiBoundary`.
  2. `naganim_c_<name>*(..., out_res: ptr CType): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].}` — C-ABI entrypoint guarded by `cAbiBoundary` (emitted when all parameters are C-ABI primitives/strings and the return type is a C-ABI primitive, `string`, `void`, or `PinnedBuffer[T]`).
  3. Compile-time registration in `gRegisteredMethods` and `gRegisteredIr`.

  **Supported `{.exportpy.}` Parameter & Return Types**:
  - Integers: `int`, `int64`, `int32`, `int16`, `int8`, `cint`, `uint`, `uint64`, `uint32`, `uint16`, `uint8`, `byte`, `csize_t`, `ptrdiff_t`, `Py_ssize_t`
  - Floats: `float`, `float64`, `float32`, `cdouble`, `cfloat`
  - Booleans & Strings: `bool`, `string`, `cstring`
  - Containers (`abi3`/`abi3t` target): `seq[byte]`, `seq[T]`, `Option[T]`, `Table[K, V]`, `tuple`
  - Zero-Copy Buffers: `PinnedBuffer[T]` (exported to Python as `memoryview` and to CFFI as `naganim_buf_view_t`), `ScopedSeqBuffer[T]` (return type on `abi3`/`abi3t`)
  - Raw Handles: `PyObj`, `PyObjectPtr`

- **`template naganimInitModule*(moduleName: static[string], moduleDoc: static[string] = "")`**
  Generates:
  - `naganim_module_ir_json*(): cstring {.exportc: "naganim_module_ir_json", cdecl, dynlib, gcsafe, raises: [].}` returning the embedded JSON IR for the module.
  - `PyInit_module*(): PyObjectPtr {.exportc: "PyInit_" & moduleName, cdecl, dynlib, gcsafe, raises: [].}` initializing the PEP 489 multi-phase `PyModuleDef` / `PyModuleDef_FT` with `Py_mod_exec` and `Py_mod_gil = Py_MOD_GIL_NOT_USED`.

#### IR Metadata Types & Helpers

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

  NaganimMethodEntry* = object
    name*: string
    doc*: string
    fn*: PyCFunction
```

- **`proc buildNaganimIrJson*(moduleName: string): string {.gcsafe, raises: [].}`**
- **`proc mapTypeToPyStub*(nimType: string): string {.compileTime.}`**
- **`proc mapTypeToCSig*(nimType: string): (bool, string) {.compileTime.}`**

---

### 1.2 `naganim/buffer` — Zero-Copy PEP 3118 & CFFI Buffers

#### Types

- **`PinnedBuffer*[T]`**: Shared-heap zero-copy buffer with unified atomic `refCount` and `exportCount`.
- **`ScopedSeqBuffer*[T]`**: Shared-heap wrapper around a `seq[T]` that guards against resize (`add`, `setLen`) while exported to Python.
- **`naganim_buf_view_t*`**: C-ABI struct (`data*: pointer`, `len*: csize_t`, `itemsize*: csize_t`, `readonly*: cint`, `ndim*: cint`, `format*: cstring`, `owner_ctx*: pointer`, `release_fn*: NaganimBufReleaseProc`) for zero-copy CFFI buffer sharing.

#### `PinnedBuffer[T]` Procedures

- **`proc newPinnedBuffer*[T](len: int, readonly: bool = false): PinnedBuffer[T]`**
  Allocates a zero-initialized `PinnedBuffer[T]` of `len` elements on the shared heap.
- **`proc newPinnedBufferFromOpenArray*[T](items: openArray[T], readonly: bool = false): PinnedBuffer[T]`**
  Allocates a `PinnedBuffer[T]` and copies `items` into it.
- **`proc len*[T](b: PinnedBuffer[T]): int`** — Element count.
- **`proc byteLen*[T](b: PinnedBuffer[T]): int`** — Total byte length (`len * sizeof(T)`).
- **`proc exportCount*[T](b: PinnedBuffer[T]): int`** — Number of active Python/CFFI views.
- **`proc refCount*[T](b: PinnedBuffer[T]): int`** — Total atomic reference count.
- **`proc dataPtr*[T](b: PinnedBuffer[T]): ptr UncheckedArray[T]`** — Raw pointer to elements.
- **`proc `[]`*[T](b: PinnedBuffer[T], idx: int): T`** — Bounds-checked element read.
- **`proc `[]=`*[T](b: var PinnedBuffer[T], idx: int, val: T)`** / **`proc writeAt*[T](b: PinnedBuffer[T], idx: int, val: T)`** — Bounds-checked element write.
- **`proc toSeq*[T](b: PinnedBuffer[T]): seq[T]`** — Copies contents into a new `seq[T]`.
- **`proc toBufView*[T](b: PinnedBuffer[T]): naganim_buf_view_t`** — Returns a C-ABI `naganim_buf_view_t` descriptor and increments both `refCount` and `exportCount`.
- **`proc toPyBufferExporterRaw*[T](b: PinnedBuffer[T]): PyObjectPtr`** — Wraps `b` in a PEP 3118 `naganim.PinnedBufferExporter` heap object.
- **`proc toPyMemoryViewRaw*[T](b: PinnedBuffer[T]): PyObjectPtr`** / **`proc toPyMemoryView*[T](b: PinnedBuffer[T]): PyObj`** — Returns a Python `memoryview` backed by `b`.

#### `ScopedSeqBuffer[T]` Procedures

- **`proc newScopedSeqBuffer*[T](initial: openArray[T] = [], readonly: bool = false): ScopedSeqBuffer[T]`**
- **`proc isNil*[T](s: ScopedSeqBuffer[T]): bool`**
- **`proc len*[T](s: ScopedSeqBuffer[T]): int`**
- **`proc exportCount*[T](s: ScopedSeqBuffer[T]): int`**
- **`proc refCount*[T](s: ScopedSeqBuffer[T]): int`**
- **`proc `[]`*[T](s: ScopedSeqBuffer[T], idx: int): T`**
- **`proc `[]=`*[T](s: ScopedSeqBuffer[T], idx: int, val: T)`**
- **`proc add*[T](s: ScopedSeqBuffer[T], val: T)`** — Appends `val`, or raises `BufferExportedDefect` if `exportCount > 0`.
- **`proc setLen*[T](s: ScopedSeqBuffer[T], newLen: int)`** — Resizes the underlying `seq[T]`, or raises `BufferExportedDefect` if `exportCount > 0`.
- **`proc toSeq*[T](s: ScopedSeqBuffer[T]): seq[T]`**
- **`proc acquireExport*[T](s: ScopedSeqBuffer[T])`** / **`proc releaseExport*[T](s: ScopedSeqBuffer[T])`**
- **`proc toPyBufferExporterRaw*[T](s: ScopedSeqBuffer[T]): PyObjectPtr`**
- **`proc toPyMemoryViewRaw*[T](s: ScopedSeqBuffer[T]): PyObjectPtr`** / **`proc toPyMemoryView*[T](s: ScopedSeqBuffer[T]): PyObj`**

#### C-ABI Buffer Release

- **`proc naganim_buf_release*(view: ptr naganim_buf_view_t) {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Invokes `view.release_fn(view.owner_ctx)` and zeroes `view`.

---

### 1.3 `naganim/gc_bridge` — `PyObj` & Deferred `Py_DecRef` Queue

#### Types & Constructors

- **`PyObj* = object`**: ORC-managed wrapper around `PyObjectPtr` (`raw*: PyObjectPtr`).
- **`proc initPyObj*(raw: PyObjectPtr, borrowed: bool = false): PyObj`** — Wraps `raw` (incrementing its refcount if `borrowed == true`).
- **`proc fromStolenPointer*(p: pointer): PyObj`** — Adopts an existing owned `PyObject*` reference without calling `Py_IncRef`.
- **`proc fromBorrowedPointer*(p: pointer): PyObj`** — Calls `Py_IncRef` (when `PyGILState_Check() == 1`) and wraps `p`.
- **`proc stealToPointer*(x: var PyObj): pointer`** — Extracts `x.raw` as `pointer` and zeroes `x.raw` so `=destroy` is a no-op (used to transfer ownership into worker closures).
- **`proc stealRaw*(x: var PyObj): PyObjectPtr`** — Extracts `x.raw` as `PyObjectPtr` and zeroes `x.raw`.
- **`proc isNil*(x: PyObj): bool`**
- **`proc refCount*(x: PyObj): int`** — Reads the object's reference count (supporting both standard `PyObject` and 32-byte Free-Threaded `PyObject_FT`).

#### Deferred `Py_DecRef` & Borrow Guards

- **`proc enqueueDeferredDecRef*(p: PyObjectPtr)`** — Enqueues `p` onto the wait-free `BQueue128` / `TreiberStack` retirement queue.
- **`proc popDeferredDecRef*(outPyObj: var pointer): bool`** — Pops a single retired `PyObject*` pointer when `activeBorrowers() == 0`.
- **`proc flushDeferredDecRefs*(): int`** (alias: **`proc drainDeferredDecRefs*(): int`**) — Drains queued pointers and calls `Py_DecRef` when `PyGILState_Check() == 1` and `activeBorrowers() == 0`.
- **`proc deferredDecRefPendingCount*(): int`** — Number of pointers waiting for reclamation.
- **`proc enterBorrow*()` / `proc exitBorrow*()` / `proc activeBorrowers*(): int`** — Cross-thread reader borrow guards.
- **`proc registerDeferredWakeupHook*(cb: DeferredWakeupProc): bool`** / **`proc unregisterDeferredWakeupHook*(cb: DeferredWakeupProc): bool`** — Registers/unregisters wakeup callbacks invoked when deferred pointers are enqueued.
- **Exported C-ABI Functions**:
  - `naganim_enter_borrow*(): cint`
  - `naganim_exit_borrow*(): cint`
  - `naganim_active_borrowers*(): cint`
  - `naganim_retire_pyobj*(pyobj: pointer): cint`
  - `naganim_pop_deferred_decref*(out_pyobj: ptr pointer): cint`
  - `naganim_pop_deferred_decref_batch*(out_pyobjs: ptr pointer, max_count: csize_t): csize_t`
  - `naganim_flush_deferred_decrefs*(): cint`
  - `naganim_deferred_decref_count*(): cint`

---

### 1.4 `naganim/conversions` — Bidirectional Type Marshaling

- **`proc toPy*[T](val: T): PyObj`** / **`proc toPyRaw*[T](val: T): PyObjectPtr`**
  Converts a Nim value (`bool`, signed/unsigned integers, floats, `string`, `cstring`, `seq[byte]`, `seq[T]`, `Option[T]`, `Table[K, V]`, `tuple`, `PinnedBuffer[T]`, `ScopedSeqBuffer[T]`, `PyObj`, `PyObjectPtr`) into a new Python object reference.
- **`proc fromPy*[T](obj: PyObj, _: typedesc[T]): T`** / **`proc fromPy*[T](obj: PyObjectPtr, _: typedesc[T]): T`** / **`proc fromPyRaw*[T](obj: PyObjectPtr, _: typedesc[T]): T`**
  Converts a Python object into the target Nim type `T` or raises `NaganimConversionError`.
- **Python Object Helpers (Nim Calling Python)**:
  - `proc pyImport*(moduleName: string): PyObj`
  - `proc getAttr*(obj: PyObj, name: string): PyObj`
  - `proc setAttr*[T](obj: PyObj, name: string, val: T)`
  - `proc callPy*(callable: PyObj, args: varargs[PyObj, toPy]): PyObj`
  - `proc `$`*(obj: PyObj): string`
  - `proc `==`*(a, b: PyObj): bool`

---

### 1.5 `naganim/lifecycle` — Runtime Initialization & Error Firewalls

- **Exception Types**: `NaganimError`, `NaganimConversionError`, `NaganimPythonError`, `BufferExportedDefect`.
- **`proc naganim_init_runtime*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Idempotent 3-state atomic `NimMain()` initialization.
- **`proc naganim_shutdown_runtime*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Flushes deferred decrefs and decrements runtime refcount.
- **`proc naganim_init_state*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Returns current initialization state (`0`..`2`).
- **`proc naganim_last_error*(): cstring {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Returns the thread-local error message from the last failed C-ABI call, or `nil`.
- **`proc naganim_set_last_error*(msg: cstring) {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Sets the thread-local error string.
- **`proc naganim_clear_error*() {.exportc, cdecl, dynlib, gcsafe, raises: [].}`** — Clears the thread-local error state.
- **`template cAbiBoundary*(body: untyped): cint`** — Catches Nim exceptions/defects at the C-ABI boundary and returns `0` (success) or negative status code (`-1`, `-2`, `-3`).
- **`template pyAbiBoundary*(body: untyped): PyObjectPtr`** — Catches Nim exceptions/defects at the `PyCFunction` boundary, sets the appropriate Python exception (`TypeError`, `BufferError`, `RuntimeError`), and returns `nil`.

---

### 1.6 `naganim/asyncio` — Native `TaskPool` & Event-Loop Wakeup Bridge

#### Nim Procedures

- **`proc createAsyncBridge*(numWorkers: int = 4): ptr NaganimAsyncBridge`**
- **`proc destroyAsyncBridge*(bridge: ptr NaganimAsyncBridge)`**
- **`proc registerAsyncComputeOp*(opCode: cint, fn: NaganimComputeOpProc): cint`**
- **`proc unregisterAsyncComputeOp*(opCode: cint): cint`**
- **`proc activeAsyncBridgeCount*(): int`**
- **`proc signalBridgeWakeup*(bridge: ptr NaganimAsyncBridge)`**
- **`proc drainWakeupPipe*(bridge: ptr NaganimAsyncBridge): int`**
- **`proc pushCompletionEvent*(bridge: ptr NaganimAsyncBridge, ev: NaganimCompletionEvent)`**
- **`proc pushCompletionString*(bridge: ptr NaganimAsyncBridge, futureId: uint64, status: cint, s: string)`**
- **`proc popCompletion*(bridge: ptr NaganimAsyncBridge, outEv: var NaganimCompletionEvent): bool`**
- **`proc submitComputeTask*(bridge: ptr NaganimAsyncBridge, futureId: uint64, opCode: cint, argA: int64, argB: int64, stolenPyObjPtr: pointer = nil)`**
- **`proc submitIntTask*(bridge: ptr NaganimAsyncBridge, futureId: uint64, fn: NaganimIntTaskProc, arg: int64)`**

#### Exported C-ABI Functions

- `naganim_async_bridge_create*(numWorkers: cint): pointer`
- `naganim_async_bridge_destroy*(bridgePtr: pointer)`
- `naganim_async_bridge_read_fd*(bridgePtr: pointer): cint`
- `naganim_async_drain_wakeup*(bridgePtr: pointer): cint`
- `naganim_async_pop_completion*(bridgePtr: pointer, outFutureId: ptr uint64, outStatus: ptr cint, outInt: ptr int64, outFloat: ptr float64, outStr: ptr cstring): cint`
- `naganim_async_register_op*(opCode: cint, fn: NaganimComputeOpProc): cint`
- `naganim_async_unregister_op*(opCode: cint): cint`
- `naganim_async_active_bridge_count*(): cint`
- `naganim_async_submit_compute*(bridgePtr: pointer, futureId: uint64, opCode: cint, argA: int64, argB: int64): cint`
- `naganim_async_channel_push_int*(bridgePtr: pointer, channelId: uint64, val: int64): cint`
- `naganim_async_channel_close*(bridgePtr: pointer, channelId: uint64): cint`

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
- **`class NaganimCffiModule(lib_path: str | Path, *, c_header_path: str | Path | None = None, nim_source_path: str | Path | None = None)`**:
  - `.lib_path: Path` — Resolved path to the shared library.
  - `.ir: NaganimModuleIr` — Parsed embedded module IR.
  - `.plugin: NaganimWriterPlugin` — Associated HeaderKit writer plugin.
  - `.ffi: cffi.FFI` — Underlying `cffi.FFI` instance.
  - `.lib: Any` — Opened `cffi` dynamic library handle.
  - `.flush_deferred_decrefs() -> int` — Flushes pending deferred `Py_DecRef` pointers via `naganim_flush_deferred_decrefs()`.
  - `.deferred_decref_count() -> int` — Returns count of pending deferred `Py_DecRef` pointers via `naganim_deferred_decref_count()`.
  - `.enter_borrow() -> int` — Increments the cross-thread reader borrow guard (`naganim_enter_borrow()`).
  - `.exit_borrow() -> int` — Decrements the cross-thread reader borrow guard (`naganim_exit_borrow()`).
  - `.active_borrowers() -> int` — Returns the current active reader borrow count (`naganim_active_borrowers()`).
  - `.retire_pyobj(ptr_addr: int) -> bool` — Enqueues a raw `PyObject*` address for deferred reclamation (`naganim_retire_pyobj()`).
  - `.pop_deferred_decref() -> int` — Pops a single deferred `PyObject*` address (`0` if empty or borrowers active).
  - `.pop_deferred_decref_batch(max_items: int = 64) -> list[int]` — Pops up to `max_items` deferred `PyObject*` addresses.
- **`class NaganimBufferOwner(ffi: cffi.FFI, lib: Any, view_ptr: Any)`**:
  Context manager wrapping a `naganim_buf_view_t*` returned over CFFI:
  - `.byte_length: int`
  - `.readonly: bool`
  - `.to_buffer() -> Any` — Returns a zero-copy `ffi.buffer` over the underlying memory.
  - `.release() -> None` — Invokes `naganim_buf_release(view_ptr)` idempotently via `weakref.finalize`.
- **`class NaganimRuntimeError(RuntimeError)`**:
  Raised when an exported Nim C-ABI function returns a non-zero status code.

---

### 2.2 Asyncio Bridge (`naganim.asyncio`)

- **`class NaganimAsyncBridge(cffi_module: NaganimCffiModule, *, num_workers: int = 4, loop: asyncio.AbstractEventLoop | None = None)`**:
  - `.read_fd: int` — Non-blocking OS pipe read descriptor monitored via `loop.add_reader`.
  - `.register_op(op_code: int, handler: Callable[[int, int], int] | Any) -> None` — Registers a CFFI callback or function pointer for `op_code` (`1 <= op_code <= 255`).
  - `.unregister_op(op_code: int) -> None` — Unregisters `op_code`.
  - `.submit_compute(op_code: int, arg_a: int = 0, arg_b: int = 0) -> asyncio.Future[int]` — Submits a compute task to the Nim `TaskPool` and returns an awaitable `asyncio.Future[int]` resolved via OS pipe wakeup without polling.
  - `.create_channel() -> AsyncChannel` — Allocates a unique channel ID and returns a bound `AsyncChannel`.
  - `.close() -> None` — Removes the event-loop reader, cancels pending futures, unregisters callbacks, and destroys the native bridge.
- **`class AsyncChannel(bridge: NaganimAsyncBridge, channel_id: int)`**:
  Implements `AsyncIterator[int]` (`async for value in channel:`), `.get() -> int`, `.put_nowait(value: int) -> None`, `.push_from_nim(value: int) -> None`, `.close_from_nim() -> None`, and `.close() -> None`.

---

### 2.3 HeaderKit Writer Plugin (`naganim.writer_plugin`)

- **`class NaganimWriterPlugin(ir: NaganimModuleIr, *, c_header_path: str | Path | None = None, c_header_code: str | None = None, nim_source_path: str | Path | None = None, jsondoc_path: str | Path | None = None)`**:
  - `NaganimWriterPlugin.from_ir_file(path: str | Path, *, c_header_path: str | Path | None = None, nim_source_path: str | Path | None = None) -> NaganimWriterPlugin`
  - `NaganimWriterPlugin.from_ir_json(json_str: str, *, c_header_path: str | Path | None = None, c_header_code: str | None = None, nim_source_path: str | Path | None = None) -> NaganimWriterPlugin`
  - `.build_jsondoc_entries() -> list[dict[str, Any]]` — Builds Nim `jsondoc` entries for `DocParserTransform`.
  - `.parse_and_clean_c_header(header_code: str | None = None, header_path: str | Path | None = None) -> Header` — Parses `nim c --header` output via `headerkit` using `NimBackend.prepare_c_parse_args()`, `clean_nim_c_unit()`, and `DocParserTransform`.
  - `.to_pyi_header() -> Header` — Builds the `headerkit.ir.Header` with Python type overrides (`Parameter.type_overrides={"pyi": ...}`, `Function.type_overrides={"pyi": ...}`, and `ParsedDoc`).
  - `.to_cffi_header() -> Header` — Builds the C-ABI `headerkit.ir.Header` for `CffiWriter`.
  - `.generate_pyi_stub() -> str` — Renders the `.pyi` stub via `NaganimPyiWriter` (`"naganim-pyi"`).
  - `.generate_cffi_cdef() -> str` — Renders the CFFI `cdef` declarations via `NaganimCffiWriter` (`"naganim-cffi"`).

---

### 2.4 CLI (`naganim`)

```bash
# Compile a .nim extension and emit shared library + .pyi + .cdef
naganim build <nim_source> [--out-dir DIR] [--out-lib PATH] [--out-pyi PATH] [--out-cdef PATH] [--header NAME] [--nim-path DIR]

# Generate .pyi and/or .cdef from a .naganim.ir.json file or compiled shared library (.so/.dylib/.dll)
naganim <source> [--header PATH] [--nim-source PATH] [--out-pyi PATH] [--out-cdef PATH]
```
