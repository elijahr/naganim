## Two-Tier Zero-Copy Buffer Protocol (`PinnedBuffer[T]`, `ScopedSeqBuffer[T]`, PEP 3118 & CFFI).
##
## Implements `design.md` §3.2 (`CRIT-04`):
## - Tier 1: `PinnedBuffer[T]` backed by `allocShared0` with atomic `refCount` and `exportCount`,
##   completely immune to `seq[T]` reallocation and `GC_ref` no-ops under Nim 2.0 `--mm:orc`.
## - Tier 2: `ScopedSeqBuffer[T]` wrapping a `seq[T]` with an atomic `exportCount` guard that
##   raises `BufferExportedDefect` (`BufferError` in Python) on any resize (`setLen`, `add`)
##   while a Python `memoryview` or CFFI buffer view is active.
## - PEP 3118 `PyType_FromSpec` heap type with `Py_bf_getbuffer` and `Py_bf_releasebuffer` slots.
## - C-ABI `naganim_buf_view_t` descriptor for `cffi` (`ffi.from_buffer`).

import std/atomics
import ./abi
import ./lifecycle
import ./gc_bridge

type
  NaganimBufReleaseProc* = proc(ctx: pointer) {.cdecl, gcsafe, raises: [].}

  naganim_buf_view_t* {.exportc: "naganim_buf_view_t", pure.} = object
    data*: pointer
    len*: csize_t
    itemsize*: csize_t
    readonly*: cint
    ndim*: cint
    format*: cstring
    owner_ctx*: pointer
    release_fn*: NaganimBufReleaseProc

  PinnedBufferHeader = object
    refCount: Atomic[int]
    exportCount: Atomic[int]
    byteLen: int
    elemLen: int
    itemSize: int
    readonly: bool
    formatStr: array[8, char]
    shapeVal: Py_ssize_t
    strideVal: Py_ssize_t
    dataPtr: pointer

  PinnedBuffer*[T] = object
    hdr*: ptr PinnedBufferHeader

  ScopedSeqHeader[T] = object
    refCount: Atomic[int]
    exportCount: Atomic[int]
    readonly: bool
    formatStr: array[8, char]
    shapeVal: Py_ssize_t
    strideVal: Py_ssize_t
    items: seq[T]

  ScopedSeqBuffer*[T] = object
    hdr*: ptr ScopedSeqHeader[T]

proc pep3118FormatFor*[T](): string {.compileTime.} =
  when T is byte or T is uint8:
    "B"
  elif T is int8:
    "b"
  elif T is int16:
    "h"
  elif T is uint16:
    "H"
  elif T is int32:
    "i"
  elif T is uint32:
    "I"
  elif T is int64 or T is int:
    "q"
  elif T is uint64 or T is uint:
    "Q"
  elif T is float32:
    "f"
  elif T is float64 or T is float:
    "d"
  elif T is bool:
    "?"
  else:
    "B"

proc setFormatChars(dst: var array[8, char], s: string) {.inline, gcsafe, raises: [].} =
  for i in 0 ..< 8:
    dst[i] = '\0'
  let n = min(s.len, 7)
  for i in 0 ..< n:
    dst[i] = s[i]

# ---------------------------------------------------------------------------
# Tier 1: PinnedBuffer[T] (allocShared0 + Unified Atomic RefCount & ExportCount)
# ---------------------------------------------------------------------------
proc releasePinnedRef(hdr: ptr PinnedBufferHeader) {.inline, gcsafe, raises: [].} =
  ## Decrements `hdr.refCount` and frees `hdr` + `hdr.dataPtr` when and only when
  ## the caller drops the last reference (`prev == 1`). Every active export holds
  ## a +1 reference in `hdr.refCount` in addition to `hdr.exportCount`, eliminating
  ## split-atomic store-buffer races and UAF windows.
  if hdr.isNil:
    return
  if hdr.refCount.fetchSub(1, moAcquireRelease) == 1:
    if not hdr.dataPtr.isNil:
      deallocShared(hdr.dataPtr)
      hdr.dataPtr = nil
    deallocShared(hdr)

proc acquirePinnedExport(hdr: ptr PinnedBufferHeader) {.inline, gcsafe, raises: [].} =
  if hdr.isNil:
    return
  discard hdr.refCount.fetchAdd(1, moAcquireRelease)
  discard hdr.exportCount.fetchAdd(1, moAcquireRelease)

proc releasePinnedExportC(ctx: pointer) {.cdecl, gcsafe, raises: [].} =
  let hdr = cast[ptr PinnedBufferHeader](ctx)
  if hdr.isNil:
    return
  discard hdr.exportCount.fetchSub(1, moAcquireRelease)
  releasePinnedRef(hdr)

proc `=destroy`*[T](b: PinnedBuffer[T]) {.gcsafe, raises: [].} =
  if not b.hdr.isNil:
    releasePinnedRef(b.hdr)

proc `=sink`*[T](dst: var PinnedBuffer[T], src: PinnedBuffer[T]) {.inline, gcsafe, raises: [].} =
  if dst.hdr != src.hdr:
    `=destroy`(dst)
    dst.hdr = src.hdr

proc `=copy`*[T](dst: var PinnedBuffer[T], src: PinnedBuffer[T]) {.inline, gcsafe, raises: [].} =
  if dst.hdr != src.hdr:
    if not src.hdr.isNil:
      discard src.hdr.refCount.fetchAdd(1, moAcquireRelease)
    `=destroy`(dst)
    dst.hdr = src.hdr

proc newPinnedBuffer*[T](len: int, readonly: bool = false): PinnedBuffer[T] {.gcsafe.} =
  if len < 0:
    raise newException(ValueError, "PinnedBuffer length cannot be negative")
  let hdr = cast[ptr PinnedBufferHeader](allocShared0(sizeof(PinnedBufferHeader)))
  hdr.refCount.store(1, moRelease)
  hdr.exportCount.store(0, moRelease)
  hdr.elemLen = len
  hdr.itemSize = sizeof(T)
  hdr.byteLen = len * sizeof(T)
  hdr.readonly = readonly
  hdr.shapeVal = Py_ssize_t(len)
  hdr.strideVal = Py_ssize_t(sizeof(T))
  setFormatChars(hdr.formatStr, pep3118FormatFor[T]())
  let allocBytes = max(hdr.byteLen, 1)
  hdr.dataPtr = allocShared0(allocBytes)
  result = PinnedBuffer[T](hdr: hdr)

proc newPinnedBufferFromOpenArray*[T](items: openArray[T], readonly: bool = false): PinnedBuffer[T] {.gcsafe.} =
  result = newPinnedBuffer[T](items.len, readonly)
  if items.len > 0:
    copyMem(result.hdr.dataPtr, unsafeAddr items[0], items.len * sizeof(T))

proc len*[T](b: PinnedBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if b.hdr.isNil: 0 else: b.hdr.elemLen

proc byteLen*[T](b: PinnedBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if b.hdr.isNil: 0 else: b.hdr.byteLen

proc exportCount*[T](b: PinnedBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if b.hdr.isNil: 0 else: b.hdr.exportCount.load(moAcquire)

proc refCount*[T](b: PinnedBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if b.hdr.isNil: 0 else: b.hdr.refCount.load(moAcquire)

proc dataPtr*[T](b: PinnedBuffer[T]): ptr UncheckedArray[T] {.inline, gcsafe, raises: [].} =
  if b.hdr.isNil: nil else: cast[ptr UncheckedArray[T]](b.hdr.dataPtr)

proc `[]`*[T](b: PinnedBuffer[T], idx: int): T {.inline, gcsafe.} =
  if b.hdr.isNil or idx < 0 or idx >= b.hdr.elemLen:
    raise newException(IndexDefect, "PinnedBuffer index out of bounds: " & $idx)
  let arr = cast[ptr UncheckedArray[T]](b.hdr.dataPtr)
  return arr[idx]

proc `[]=`*[T](b: var PinnedBuffer[T], idx: int, val: T) {.inline, gcsafe.} =
  if b.hdr.isNil or idx < 0 or idx >= b.hdr.elemLen:
    raise newException(IndexDefect, "PinnedBuffer index out of bounds: " & $idx)
  let arr = cast[ptr UncheckedArray[T]](b.hdr.dataPtr)
  arr[idx] = val

proc writeAt*[T](b: PinnedBuffer[T], idx: int, val: T) {.inline, gcsafe.} =
  if b.hdr.isNil or idx < 0 or idx >= b.hdr.elemLen:
    raise newException(IndexDefect, "PinnedBuffer index out of bounds: " & $idx)
  let arr = cast[ptr UncheckedArray[T]](b.hdr.dataPtr)
  arr[idx] = val

proc toSeq*[T](b: PinnedBuffer[T]): seq[T] {.gcsafe.} =
  if b.hdr.isNil or b.hdr.elemLen == 0:
    return @[]
  result = newSeq[T](b.hdr.elemLen)
  copyMem(addr result[0], b.hdr.dataPtr, b.hdr.byteLen)

proc toBufView*[T](b: PinnedBuffer[T]): naganim_buf_view_t {.gcsafe, raises: [].} =
  ## Exports a zero-copy C-ABI `naganim_buf_view_t` descriptor and increments
  ## both `refCount` and `exportCount`. Caller must invoke `naganim_buf_release(addr view)` when done.
  if b.hdr.isNil:
    return naganim_buf_view_t()
  acquirePinnedExport(b.hdr)
  result = naganim_buf_view_t(
    data: b.hdr.dataPtr,
    len: csize_t(b.hdr.byteLen),
    itemsize: csize_t(b.hdr.itemSize),
    readonly: if b.hdr.readonly: 1 else: 0,
    ndim: 1,
    format: cast[cstring](addr b.hdr.formatStr[0]),
    owner_ctx: cast[pointer](b.hdr),
    release_fn: releasePinnedExportC
  )

proc naganim_buf_release*(view: ptr naganim_buf_view_t) {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  if view.isNil:
    return
  if not view.release_fn.isNil:
    view.release_fn(view.owner_ctx)
    view.release_fn = nil
    view.owner_ctx = nil
    view.data = nil
    view.len = 0

# ---------------------------------------------------------------------------
# Tier 2: ScopedSeqBuffer[T] (Shared-Heap Atomic RefCount & ExportCount)
# ---------------------------------------------------------------------------
proc releaseScopedSeqRef[T](hdr: ptr ScopedSeqHeader[T]) {.inline, gcsafe, raises: [].} =
  if hdr.isNil:
    return
  if hdr.refCount.fetchSub(1, moAcquireRelease) == 1:
    {.cast(gcsafe), cast(raises: []).}:
      `=destroy`(hdr.items)
    deallocShared(hdr)

proc `=destroy`*[T](s: ScopedSeqBuffer[T]) {.gcsafe, raises: [].} =
  if not s.hdr.isNil:
    releaseScopedSeqRef(s.hdr)

proc `=sink`*[T](dst: var ScopedSeqBuffer[T], src: ScopedSeqBuffer[T]) {.inline, gcsafe, raises: [].} =
  if dst.hdr != src.hdr:
    `=destroy`(dst)
    dst.hdr = src.hdr

proc `=copy`*[T](dst: var ScopedSeqBuffer[T], src: ScopedSeqBuffer[T]) {.inline, gcsafe, raises: [].} =
  if dst.hdr != src.hdr:
    if not src.hdr.isNil:
      discard src.hdr.refCount.fetchAdd(1, moAcquireRelease)
    `=destroy`(dst)
    dst.hdr = src.hdr

proc isNil*[T](s: ScopedSeqBuffer[T]): bool {.inline, gcsafe, raises: [].} =
  s.hdr.isNil

proc newScopedSeqBuffer*[T](initial: openArray[T] = [], readonly: bool = false): ScopedSeqBuffer[T] {.gcsafe.} =
  let hdr = cast[ptr ScopedSeqHeader[T]](allocShared0(sizeof(ScopedSeqHeader[T])))
  hdr.refCount.store(1, moRelease)
  hdr.exportCount.store(0, moRelease)
  hdr.readonly = readonly
  setFormatChars(hdr.formatStr, pep3118FormatFor[T]())
  hdr.items = @initial
  hdr.shapeVal = Py_ssize_t(hdr.items.len)
  hdr.strideVal = Py_ssize_t(sizeof(T))
  result = ScopedSeqBuffer[T](hdr: hdr)

proc checkNotExported*[T](s: ScopedSeqBuffer[T], opName: string) {.inline, gcsafe.} =
  if s.hdr.isNil:
    raise newException(NaganimError, "ScopedSeqBuffer is nil")
  let active = s.hdr.exportCount.load(moAcquire)
  if active > 0:
    raise newException(
      BufferExportedDefect,
      "Cannot resize or reallocate ScopedSeqBuffer via `" & opName & "` while " &
      $active & " active buffer view(s) are exported"
    )

proc len*[T](s: ScopedSeqBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if s.hdr.isNil: 0 else: s.hdr.items.len

proc exportCount*[T](s: ScopedSeqBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if s.hdr.isNil: 0 else: s.hdr.exportCount.load(moAcquire)

proc refCount*[T](s: ScopedSeqBuffer[T]): int {.inline, gcsafe, raises: [].} =
  if s.hdr.isNil: 0 else: s.hdr.refCount.load(moAcquire)

proc `[]`*[T](s: ScopedSeqBuffer[T], idx: int): T {.inline, gcsafe.} =
  s.hdr.items[idx]

proc `[]=`*[T](s: ScopedSeqBuffer[T], idx: int, val: T) {.inline, gcsafe.} =
  if s.hdr.isNil or s.hdr.readonly:
    raise newException(NaganimError, "Cannot mutate readonly ScopedSeqBuffer")
  s.hdr.items[idx] = val

proc add*[T](s: ScopedSeqBuffer[T], val: T) {.gcsafe.} =
  s.checkNotExported("add")
  s.hdr.items.add(val)
  s.hdr.shapeVal = Py_ssize_t(s.hdr.items.len)

proc setLen*[T](s: ScopedSeqBuffer[T], newLen: int) {.gcsafe.} =
  s.checkNotExported("setLen")
  s.hdr.items.setLen(newLen)
  s.hdr.shapeVal = Py_ssize_t(s.hdr.items.len)

proc toSeq*[T](s: ScopedSeqBuffer[T]): seq[T] {.inline, gcsafe.} =
  if s.hdr.isNil: @[] else: s.hdr.items

proc acquireExport*[T](s: ScopedSeqBuffer[T]) {.inline, gcsafe, raises: [].} =
  if not s.hdr.isNil:
    discard s.hdr.refCount.fetchAdd(1, moAcquireRelease)
    discard s.hdr.exportCount.fetchAdd(1, moAcquireRelease)

proc releaseExport*[T](s: ScopedSeqBuffer[T]) {.inline, gcsafe, raises: [].} =
  if not s.hdr.isNil:
    discard s.hdr.exportCount.fetchSub(1, moAcquireRelease)
    releaseScopedSeqRef(s.hdr)

# ---------------------------------------------------------------------------
# PEP 3118 Heap-Type Buffer Exporter (`PyType_FromSpec` with getbuffer/releasebuffer)
# ---------------------------------------------------------------------------
type
  ScopedGetBufferProc = proc(ctx: pointer, exporter: PyObjectPtr, view: ptr Py_buffer, flags: cint): cint {.cdecl, gcsafe, raises: [].}

  NaganimPyBufferObj = object
    # 32-byte base header padding: accommodates both 16-byte standard abi3
    # PyObject header and 32-byte free-threaded abi3t (3.13t/3.14t) PyObject
    # header (ob_tid, _padding, ob_mutex, ob_gc_bits, ob_ref_local,
    # ob_ref_shared, ob_type) without overlapping `hdr`.
    ob_base_pad: array[32, byte]
    hdr: ptr PinnedBufferHeader
    scopedCtx: pointer
    scopedGetBufferFn: ScopedGetBufferProc
    scopedReleaseFn: NaganimBufReleaseProc
    scopedDeallocFn: NaganimBufReleaseProc

var
  gBufferTypeInitState: Atomic[int32]
  gBufferTypeObj: Atomic[pointer] # PyObjectPtr to the PEP 384 heap type
  gBufferTypeSlots: array[4, PyType_Slot]
  gBufferTypeSpec: PyType_Spec
  gEmptyScopedByte: byte = 0

proc applyPep3118Flags(
  view: ptr Py_buffer,
  flags: cint,
  itemSize: Py_ssize_t,
  formatCStr: cstring,
  shapePtr: ptr Py_ssize_t,
  stridePtr: ptr Py_ssize_t
) {.inline, gcsafe, raises: [].} =
  view.itemsize = itemSize
  view.format = if (flags and PyBUF_FORMAT) != 0: formatCStr else: nil
  if (flags and PyBUF_ND) != 0:
    view.ndim = 1
    view.shape = shapePtr
    view.strides = if (flags and PyBUF_STRIDES) != 0: stridePtr else: nil
  else:
    view.ndim = 0
    view.shape = nil
    view.strides = nil
  view.suboffsets = nil

proc naganimPyBufferGetBuffer(self: PyObjectPtr, view: ptr Py_buffer, flags: cint): cint {.cdecl, gcsafe, raises: [].} =
  if self.isNil or view.isNil:
    PyErr_SetString(PyExc_BufferError, "NULL buffer exporter or Py_buffer view")
    return -1
  let obj = cast[ptr NaganimPyBufferObj](self)
  if not obj.scopedCtx.isNil and not obj.scopedGetBufferFn.isNil:
    return obj.scopedGetBufferFn(obj.scopedCtx, self, view, flags)
  let hdr = obj.hdr
  if hdr.isNil or hdr.dataPtr.isNil:
    PyErr_SetString(PyExc_BufferError, "Detached PinnedBuffer")
    return -1
  if (flags and PyBUF_WRITABLE) != 0 and hdr.readonly:
    PyErr_SetString(PyExc_BufferError, "PinnedBuffer is read-only")
    return -1
  let roFlag: cint = if hdr.readonly: 1 else: 0
  if PyBuffer_FillInfo(view, self, hdr.dataPtr, Py_ssize_t(hdr.byteLen), roFlag, flags) != 0:
    return -1
  applyPep3118Flags(
    view,
    flags,
    Py_ssize_t(hdr.itemSize),
    cast[cstring](addr hdr.formatStr[0]),
    addr hdr.shapeVal,
    addr hdr.strideVal
  )
  acquirePinnedExport(hdr)
  return 0

proc naganimPyBufferReleaseBuffer(self: PyObjectPtr, view: ptr Py_buffer) {.cdecl, gcsafe, raises: [].} =
  discard view
  if self.isNil:
    return
  let obj = cast[ptr NaganimPyBufferObj](self)
  if not obj.scopedCtx.isNil and not obj.scopedReleaseFn.isNil:
    obj.scopedReleaseFn(obj.scopedCtx)
    return
  if not obj.hdr.isNil:
    releasePinnedExportC(cast[pointer](obj.hdr))

proc naganimPyBufferDealloc(self: PyObjectPtr) {.cdecl, gcsafe, raises: [].} =
  if self.isNil:
    return
  var tp = pyTypeOf(self)
  if tp.isNil:
    tp = cast[PyObjectPtr](gBufferTypeObj.load(moAcquire))
  let obj = cast[ptr NaganimPyBufferObj](self)
  if not obj.scopedCtx.isNil and not obj.scopedDeallocFn.isNil:
    let ctx = obj.scopedCtx
    let deallocFn = obj.scopedDeallocFn
    obj.scopedCtx = nil
    obj.scopedDeallocFn = nil
    obj.scopedGetBufferFn = nil
    obj.scopedReleaseFn = nil
    deallocFn(ctx)
  if not obj.hdr.isNil:
    let hdr = obj.hdr
    obj.hdr = nil
    releasePinnedRef(hdr)
  PyObject_Free(cast[pointer](self))
  if not tp.isNil:
    Py_DecRef(tp)

proc ensurePyBufferType*(): PyObjectPtr {.gcsafe, raises: [].} =
  if likely(gBufferTypeInitState.load(moAcquire) == 2'i32):
    return cast[PyObjectPtr](gBufferTypeObj.load(moAcquire))
  var expected = 0'i32
  if gBufferTypeInitState.compareExchange(expected, 1'i32, moAcquireRelease, moAcquire):
    gBufferTypeSlots[0] = PyType_Slot(slot: Py_bf_getbuffer, pfunc: cast[pointer](naganimPyBufferGetBuffer))
    gBufferTypeSlots[1] = PyType_Slot(slot: Py_bf_releasebuffer, pfunc: cast[pointer](naganimPyBufferReleaseBuffer))
    gBufferTypeSlots[2] = PyType_Slot(slot: Py_tp_dealloc, pfunc: cast[pointer](naganimPyBufferDealloc))
    gBufferTypeSlots[3] = PyType_Slot(slot: 0, pfunc: nil)
    gBufferTypeSpec = PyType_Spec(
      name: "naganim.PinnedBufferExporter",
      basicsize: cint(sizeof(NaganimPyBufferObj)),
      itemsize: 0,
      flags: Py_TPFLAGS_DEFAULT,
      slots: addr gBufferTypeSlots[0]
    )
    let tp = PyType_FromSpec(addr gBufferTypeSpec)
    if not tp.isNil:
      gBufferTypeObj.store(cast[pointer](tp), moRelease)
      gBufferTypeInitState.store(2'i32, moRelease)
    else:
      gBufferTypeInitState.store(0'i32, moRelease)
    return tp
  else:
    while gBufferTypeInitState.load(moAcquire) == 1'i32:
      cpuRelax()
    return cast[PyObjectPtr](gBufferTypeObj.load(moAcquire))

proc toPyBufferExporterRaw*[T](b: PinnedBuffer[T]): PyObjectPtr {.gcsafe.} =
  ## Creates a PEP 3118 `naganim.PinnedBufferExporter` Python object sharing
  ## zero-copy memory with `b` and tracking `exportCount` on `memoryview`
  ## acquisition/release.
  discard flushDeferredDecRefs()
  if b.hdr.isNil:
    raise newException(NaganimConversionError, "Cannot export nil PinnedBuffer to Python")
  let tp = ensurePyBufferType()
  if tp.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  let emptyTuple = PyTuple_New(0)
  if emptyTuple.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  let rawObj = PyType_GenericNew(tp, emptyTuple, nil)
  Py_DecRef(emptyTuple)
  if rawObj.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  let bufObj = cast[ptr NaganimPyBufferObj](rawObj)
  discard b.hdr.refCount.fetchAdd(1, moAcquireRelease)
  bufObj.hdr = b.hdr
  bufObj.scopedCtx = nil
  bufObj.scopedGetBufferFn = nil
  bufObj.scopedReleaseFn = nil
  bufObj.scopedDeallocFn = nil
  return rawObj

proc toPyMemoryViewRaw*[T](b: PinnedBuffer[T]): PyObjectPtr {.gcsafe.} =
  ## Returns a Python `memoryview` backed by `b`'s PEP 3118 exporter object
  ## so `exportCount` is incremented immediately and decremented when the
  ## `memoryview` is released or garbage-collected.
  let exporter = toPyBufferExporterRaw(b)
  let mv = PyMemoryView_FromObject(exporter)
  Py_DecRef(exporter)
  if mv.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  return mv

proc toPyMemoryView*[T](b: PinnedBuffer[T]): PyObj {.gcsafe.} =
  initPyObj(toPyMemoryViewRaw(b), borrowed = false)

proc toPyRaw*[T](val: PinnedBuffer[T]): PyObjectPtr {.inline, gcsafe.} =
  toPyMemoryViewRaw(val)

proc scopedSeqGetBufferC[T](ctx: pointer, exporter: PyObjectPtr, view: ptr Py_buffer, flags: cint): cint {.cdecl, gcsafe, raises: [].} =
  if ctx.isNil or exporter.isNil or view.isNil:
    PyErr_SetString(PyExc_BufferError, "NULL ScopedSeqBuffer exporter or Py_buffer view")
    return -1
  let hdr = cast[ptr ScopedSeqHeader[T]](ctx)
  if (flags and PyBUF_WRITABLE) != 0 and hdr.readonly:
    PyErr_SetString(PyExc_BufferError, "ScopedSeqBuffer is read-only")
    return -1
  let roFlag: cint = if hdr.readonly: 1 else: 0
  let byteLen = hdr.items.len * sizeof(T)
  let rawPtr: pointer =
    if hdr.items.len > 0:
      cast[pointer](addr hdr.items[0])
    else:
      cast[pointer](addr gEmptyScopedByte)
  if PyBuffer_FillInfo(view, exporter, rawPtr, Py_ssize_t(byteLen), roFlag, flags) != 0:
    return -1
  hdr.shapeVal = Py_ssize_t(hdr.items.len)
  hdr.strideVal = Py_ssize_t(sizeof(T))
  applyPep3118Flags(
    view,
    flags,
    Py_ssize_t(sizeof(T)),
    cast[cstring](addr hdr.formatStr[0]),
    addr hdr.shapeVal,
    addr hdr.strideVal
  )
  discard hdr.refCount.fetchAdd(1, moAcquireRelease)
  discard hdr.exportCount.fetchAdd(1, moAcquireRelease)
  return 0

proc scopedSeqReleaseBufferC[T](ctx: pointer) {.cdecl, gcsafe, raises: [].} =
  if ctx.isNil:
    return
  let hdr = cast[ptr ScopedSeqHeader[T]](ctx)
  discard hdr.exportCount.fetchSub(1, moAcquireRelease)
  releaseScopedSeqRef(hdr)

proc scopedSeqDeallocC[T](ctx: pointer) {.cdecl, gcsafe, raises: [].} =
  if ctx.isNil:
    return
  let hdr = cast[ptr ScopedSeqHeader[T]](ctx)
  releaseScopedSeqRef(hdr)

proc toPyBufferExporterRaw*[T](s: ScopedSeqBuffer[T]): PyObjectPtr {.gcsafe.} =
  ## Creates a PEP 3118 `naganim.PinnedBufferExporter` Python object sharing
  ## zero-copy memory with `s` and tracking `s.exportCount` on `memoryview`
  ## acquisition/release so `s.add` / `s.setLen` raise `BufferExportedDefect`
  ## while exported. Uses shared-heap atomic `refCount` instead of `GC_ref`/`GC_unref`.
  discard flushDeferredDecRefs()
  if s.hdr.isNil:
    raise newException(NaganimConversionError, "Cannot export nil ScopedSeqBuffer to Python")
  let tp = ensurePyBufferType()
  if tp.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  let emptyTuple = PyTuple_New(0)
  if emptyTuple.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  let rawObj = PyType_GenericNew(tp, emptyTuple, nil)
  Py_DecRef(emptyTuple)
  if rawObj.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  let bufObj = cast[ptr NaganimPyBufferObj](rawObj)
  discard s.hdr.refCount.fetchAdd(1, moAcquireRelease)
  bufObj.hdr = nil
  bufObj.scopedCtx = cast[pointer](s.hdr)
  bufObj.scopedGetBufferFn = scopedSeqGetBufferC[T]
  bufObj.scopedReleaseFn = scopedSeqReleaseBufferC[T]
  bufObj.scopedDeallocFn = scopedSeqDeallocC[T]
  return rawObj

proc toPyMemoryViewRaw*[T](s: ScopedSeqBuffer[T]): PyObjectPtr {.gcsafe.} =
  let exporter = toPyBufferExporterRaw(s)
  let mv = PyMemoryView_FromObject(exporter)
  Py_DecRef(exporter)
  if mv.isNil:
    raise newException(NaganimConversionError, fetchPythonErrorMessage())
  return mv

proc toPyMemoryView*[T](s: ScopedSeqBuffer[T]): PyObj {.gcsafe.} =
  initPyObj(toPyMemoryViewRaw(s), borrowed = false)

proc toPyRaw*[T](val: ScopedSeqBuffer[T]): PyObjectPtr {.inline, gcsafe.} =
  toPyMemoryViewRaw(val)

