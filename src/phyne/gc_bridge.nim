## Wait-Free Deferred `Py_DecRef` Queue & ORC-CPython Reference Counting Bridge.
##
## Implements `design.md` §3.1 (`CRIT-01` & `HIGH-02`):
## - `PyObj` wrapper with Nim 2.0 ORC lifecycle hooks (`=destroy`, `=copy`, `=sink`)
## - Wait-free deferred `Py_DecRef` queue backed by `lockfree/bqueue128` (`BQueue128[pointer, 4096]`)
##   and overflow `lockfree/stack` (`TreiberStack[pointer]`) so Nim ORC destructors
##   running on arbitrary non-Python worker threads never call `Py_DecRef` without
##   an attached `PyThreadState` or block on `PyGILState_Ensure()`.
## - Raw pointer ownership transfer (`stealToPointer`, `fromStolenPointer`,
##   `fromBorrowedPointer`) for safe `TaskPool` closure capture (`HIGH-01`).

import std/[atomics, options]
import lockfree/bqueue128
import lockfree/stack
import ./abi
import ./lifecycle

type
  PyObj* = object
    raw*: PyObjectPtr

var
  gDeferredQueueInitLock: AtomicFlag
  gDeferredQueueInitialized: Atomic[bool]
  gDeferredDecRefQueuePtr*: ptr BQueue128[pointer, 4096]
  gOverflowDecRefStack*: TreiberStack[pointer]
  gDeferredPendingCount*: Atomic[int]
  gForceDeferredDecRef*: Atomic[bool] ## Test hook to simulate non-Python worker thread destruction
  gDeferredWakeupCallback*: Atomic[pointer] ## Optional `proc() {.cdecl, gcsafe, raises: [].}` for 0->1 wakeup

proc ensureDeferredQueueInitialized*() {.gcsafe, raises: [].} =
  if gDeferredQueueInitialized.load(moAcquire):
    return
  while gDeferredQueueInitLock.testAndSet(moAcquire):
    cpuRelax()
  if not gDeferredQueueInitialized.load(moRelaxed):
    {.cast(gcsafe), cast(raises: []).}:
      gDeferredDecRefQueuePtr = allocAlignedBQueue128[pointer, 4096]()
      gOverflowDecRefStack = initTreiberStack[pointer]()
    gDeferredQueueInitialized.store(true, moRelease)
  gDeferredQueueInitLock.clear(moRelease)

proc hasPythonThreadState*(): bool {.inline, gcsafe, raises: [].} =
  ## Returns true if and only if CPython is initialized, the current OS thread
  ## holds an active Python thread state (`PyGILState_Check() != 0`), and
  ## deferred-mode forcing is not enabled.
  if gForceDeferredDecRef.load(moRelaxed):
    return false
  if Py_IsInitialized() == 0:
    return false
  return PyGILState_Check() != 0

proc enqueueDeferredDecRef*(p: PyObjectPtr) {.gcsafe, raises: [].} =
  ## Wait-free/lock-free enqueue of a `PyObjectPtr` whose reference count must be
  ## decremented on a thread with an active Python thread state.
  if p.isNil:
    return
  ensureDeferredQueueInitialized()
  let rawPtr = cast[pointer](p)
  var pushedToRing = false
  var transitionedFromEmpty = false
  {.cast(gcsafe), cast(raises: []).}:
    pushedToRing = gDeferredDecRefQueuePtr[].tryPushEx(rawPtr, transitionedFromEmpty)
    if not pushedToRing:
      gOverflowDecRefStack.push(rawPtr)
  let prev = gDeferredPendingCount.fetchAdd(1, moAcquireRelease)
  if prev == 0 or transitionedFromEmpty:
    let cbPtr = gDeferredWakeupCallback.load(moAcquire)
    if not cbPtr.isNil:
      let cb = cast[proc() {.cdecl, gcsafe, raises: [].}](cbPtr)
      cb()

proc flushDeferredDecRefs*(): int {.discardable, gcsafe, raises: [].} =
  ## Drains all pending `PyObjectPtr` pointers from `gDeferredDecRefQueuePtr` and
  ## `gOverflowDecRefStack` and invokes `Py_DecRef` on each.
  ## Must be called when `hasPythonThreadState()` is true (or ignores if not).
  if not gDeferredQueueInitialized.load(moAcquire):
    return 0
  if Py_IsInitialized() == 0 or PyGILState_Check() == 0:
    return 0
  var drained = 0
  var rawItem: pointer = nil
  {.cast(gcsafe), cast(raises: []).}:
    while gDeferredDecRefQueuePtr[].tryPop(rawItem):
      if not rawItem.isNil:
        Py_DecRef(cast[PyObjectPtr](rawItem))
        inc drained
        discard gDeferredPendingCount.fetchSub(1, moAcquireRelease)
    while true:
      let opt = gOverflowDecRefStack.pop()
      if opt.isNone:
        break
      rawItem = opt.get()
      if not rawItem.isNil:
        Py_DecRef(cast[PyObjectPtr](rawItem))
        inc drained
        discard gDeferredPendingCount.fetchSub(1, moAcquireRelease)
  return drained

proc flushDeferredDecRefsCAbi() {.cdecl, gcsafe, raises: [].} =
  discard flushDeferredDecRefs()

# Register the deferred flush hook with lifecycle so every phyne_init_runtime /
# phyne_shutdown_runtime / boundary entry automatically drains queued DecRefs.
gDeferredFlushHook = flushDeferredDecRefsCAbi

proc deferredDecRefPendingCount*(): int {.inline, gcsafe, raises: [].} =
  gDeferredPendingCount.load(moAcquire)

proc phyne_flush_deferred_decrefs*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cint(flushDeferredDecRefs())

proc phyne_deferred_decref_count*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cint(deferredDecRefPendingCount())

# ---------------------------------------------------------------------------
# Nim 2.0 ORC Reference Counting Hooks for PyObj
# ---------------------------------------------------------------------------
proc `=destroy`*(x: PyObj) {.gcsafe, raises: [].} =
  if x.raw != nil:
    if hasPythonThreadState():
      discard flushDeferredDecRefs()
      Py_DecRef(x.raw)
    else:
      enqueueDeferredDecRef(x.raw)

proc `=sink`*(dst: var PyObj, src: PyObj) {.inline, gcsafe, raises: [].} =
  if dst.raw != nil and dst.raw != src.raw:
    if hasPythonThreadState():
      discard flushDeferredDecRefs()
      Py_DecRef(dst.raw)
    else:
      enqueueDeferredDecRef(dst.raw)
  dst.raw = src.raw

proc `=copy`*(dst: var PyObj, src: PyObj) {.gcsafe, raises: [].} =
  if dst.raw != src.raw:
    if src.raw != nil:
      if hasPythonThreadState():
        Py_IncRef(src.raw)
      else:
        let gstate = PyGILState_Ensure()
        Py_IncRef(src.raw)
        PyGILState_Release(gstate)
    if dst.raw != nil:
      if hasPythonThreadState():
        discard flushDeferredDecRefs()
        Py_DecRef(dst.raw)
      else:
        enqueueDeferredDecRef(dst.raw)
    dst.raw = src.raw

# ---------------------------------------------------------------------------
# Ownership Transfer Helpers (design.md §3.1 HIGH-01)
# ---------------------------------------------------------------------------
proc initPyObj*(raw: PyObjectPtr, borrowed: bool = false): PyObj {.inline, gcsafe, raises: [].} =
  ## Wraps a `PyObjectPtr` into a `PyObj`. If `borrowed` is true, increments the
  ## Python reference count first; otherwise takes ownership of a stolen reference.
  if raw != nil and borrowed:
    if hasPythonThreadState():
      Py_IncRef(raw)
    else:
      let gstate = PyGILState_Ensure()
      Py_IncRef(raw)
      PyGILState_Release(gstate)
  result = PyObj(raw: raw)

proc isNil*(x: PyObj): bool {.inline, gcsafe, raises: [].} =
  x.raw.isNil

proc stealToPointer*(x: var PyObj): pointer {.inline, gcsafe, raises: [].} =
  ## Transfers the underlying `PyObjectPtr` out of `x` as an opaque `pointer`
  ## without decrementing the Python reference count, setting `x.raw = nil`
  ## so `=destroy` is a no-op on `x`. Used when passing `PyObj` across C `void*`
  ## boundaries (such as `TaskPool` task contexts).
  result = cast[pointer](x.raw)
  x.raw = nil

proc stealRaw*(x: var PyObj): PyObjectPtr {.inline, gcsafe, raises: [].} =
  ## Transfers the underlying `PyObjectPtr` out of `x` to return a new reference
  ## to CPython without decrementing `ob_refcnt`.
  result = x.raw
  x.raw = nil

proc fromStolenPointer*(p: pointer): PyObj {.inline, gcsafe, raises: [].} =
  ## Reconstructs a `PyObj` taking ownership of an already-incremented (`stolen`)
  ## `PyObjectPtr` passed as a raw `pointer`.
  result = PyObj(raw: cast[PyObjectPtr](p))

proc fromBorrowedPointer*(p: pointer): PyObj {.inline, gcsafe, raises: [].} =
  ## Reconstructs a `PyObj` from a borrowed `PyObjectPtr` by incrementing its
  ## reference count first.
  let raw = cast[PyObjectPtr](p)
  if raw != nil:
    if hasPythonThreadState():
      Py_IncRef(raw)
    else:
      let gstate = PyGILState_Ensure()
      Py_IncRef(raw)
      PyGILState_Release(gstate)
  result = PyObj(raw: raw)

proc refCount*(x: PyObj): int {.inline, gcsafe, raises: [].} =
  if x.raw.isNil:
    return 0
  return int(x.raw[].ob_refcnt)
