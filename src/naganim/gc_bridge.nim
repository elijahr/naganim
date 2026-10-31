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

const
  MaxDeferredWakeupHooks* = 64

type
  PyObj* = object
    raw*: PyObjectPtr

  DeferredWakeupProc* = proc() {.cdecl, gcsafe, raises: [].}

var
  gDeferredQueueInitState: Atomic[int32] # 0 = Uninit, 1 = Initializing, 2 = Ready
  gDeferredDecRefQueuePtr*: ptr BQueue128[pointer, 4096]
  gOverflowDecRefStack*: TreiberStack[pointer]
  gDeferredPendingCount*: Atomic[int]
  gActiveBorrowers*: Atomic[int]
  gForceDeferredDecRef*: Atomic[bool] ## Test hook to simulate non-Python worker thread destruction
  gDeferredWakeupCallback*: Atomic[pointer] ## Optional primary `DeferredWakeupProc` for 0->1 wakeup
  gDeferredWakeupHooks: array[MaxDeferredWakeupHooks, Atomic[pointer]]

proc registerDeferredWakeupHook*(cb: DeferredWakeupProc): bool {.discardable, gcsafe, raises: [].} =
  if cb.isNil:
    return false
  let rawCb = cast[pointer](cb)
  for i in 0 ..< MaxDeferredWakeupHooks:
    if gDeferredWakeupHooks[i].load(moAcquire) == rawCb:
      return true
  for i in 0 ..< MaxDeferredWakeupHooks:
    var expected: pointer = nil
    if gDeferredWakeupHooks[i].compareExchange(expected, rawCb, moAcquireRelease, moAcquire):
      return true
  return false

proc unregisterDeferredWakeupHook*(cb: DeferredWakeupProc): bool {.discardable, gcsafe, raises: [].} =
  if cb.isNil:
    return false
  let rawCb = cast[pointer](cb)
  for i in 0 ..< MaxDeferredWakeupHooks:
    var expected = rawCb
    if gDeferredWakeupHooks[i].compareExchange(expected, nil, moAcquireRelease, moRelaxed):
      return true
  return false

proc notifyDeferredWakeupHooks() {.inline, gcsafe, raises: [].} =
  let primaryPtr = gDeferredWakeupCallback.load(moAcquire)
  if not primaryPtr.isNil:
    let cb = cast[DeferredWakeupProc](primaryPtr)
    cb()
  for i in 0 ..< MaxDeferredWakeupHooks:
    let hPtr = gDeferredWakeupHooks[i].load(moAcquire)
    if not hPtr.isNil and hPtr != primaryPtr:
      let cb = cast[DeferredWakeupProc](hPtr)
      cb()

proc ensureDeferredQueueInitialized*() {.gcsafe, raises: [].} =
  if likely(gDeferredQueueInitState.load(moAcquire) == 2'i32):
    return
  var expected = 0'i32
  if gDeferredQueueInitState.compareExchange(expected, 1'i32, moAcquireRelease, moAcquire):
    {.cast(gcsafe), cast(raises: []).}:
      gDeferredDecRefQueuePtr = allocAlignedBQueue128[pointer, 4096]()
      gOverflowDecRefStack = initTreiberStack[pointer]()
    gDeferredQueueInitState.store(2'i32, moRelease)
  else:
    while gDeferredQueueInitState.load(moAcquire) != 2'i32:
      cpuRelax()

proc enterBorrow*() {.inline, gcsafe, raises: [].} =
  ## Marks the current thread as holding a transient borrowed `PyObject*` pointer
  ## across a lock-free container read, suspending deferred `Py_DecRef` draining
  ## until `exitBorrow()` is called.
  discard gActiveBorrowers.fetchAdd(1, moAcquireRelease)

proc exitBorrow*() {.inline, gcsafe, raises: [].} =
  ## Releases a borrow guard acquired via `enterBorrow()`.
  let prev = gActiveBorrowers.fetchSub(1, moAcquireRelease)
  if prev <= 0:
    gActiveBorrowers.store(0, moRelease)

proc activeBorrowers*(): int {.inline, gcsafe, raises: [].} =
  gActiveBorrowers.load(moAcquire)

proc naganim_enter_borrow*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  enterBorrow()
  cint(activeBorrowers())

proc naganim_exit_borrow*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  exitBorrow()
  cint(activeBorrowers())

proc naganim_active_borrowers*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cint(activeBorrowers())

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
    notifyDeferredWakeupHooks()

proc naganim_retire_pyobj*(pyobj: pointer): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  if pyobj.isNil:
    return 0
  enqueueDeferredDecRef(cast[PyObjectPtr](pyobj))
  return 1

proc popDeferredDecRef*(outPyObj: var pointer): bool {.gcsafe, raises: [].} =
  ## Pops a single deferred `PyObject*` pointer for reclamation if and only if
  ## no borrower guard (`gActiveBorrowers > 0`) is currently active.
  if gActiveBorrowers.load(moAcquire) > 0:
    outPyObj = nil
    return false
  if gDeferredQueueInitState.load(moAcquire) != 2'i32 or gDeferredPendingCount.load(moAcquire) <= 0:
    outPyObj = nil
    return false
  var rawItem: pointer = nil
  {.cast(gcsafe), cast(raises: []).}:
    if gDeferredDecRefQueuePtr[].tryPop(rawItem):
      discard gDeferredPendingCount.fetchSub(1, moAcquireRelease)
      outPyObj = rawItem
      return true
    let opt = gOverflowDecRefStack.pop()
    if opt.isSome:
      discard gDeferredPendingCount.fetchSub(1, moAcquireRelease)
      outPyObj = opt.get()
      return true
  outPyObj = nil
  return false

proc naganim_pop_deferred_decref*(out_pyobj: ptr pointer): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  if out_pyobj.isNil:
    return 0
  var item: pointer = nil
  if popDeferredDecRef(item):
    out_pyobj[] = item
    return 1
  out_pyobj[] = nil
  return 0

proc naganim_pop_deferred_decref_batch*(
  out_pyobjs: ptr pointer, max_count: csize_t
): csize_t {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  if out_pyobjs.isNil or max_count == 0 or gActiveBorrowers.load(moAcquire) > 0:
    return 0
  let arr = cast[ptr UncheckedArray[pointer]](out_pyobjs)
  var count: csize_t = 0
  var item: pointer = nil
  while count < max_count and popDeferredDecRef(item):
    arr[int(count)] = item
    inc count
  return count

proc flushDeferredDecRefs*(): int {.discardable, gcsafe, raises: [].} =
  ## Drains all pending `PyObjectPtr` pointers from `gDeferredDecRefQueuePtr` and
  ## `gOverflowDecRefStack` and invokes `Py_DecRef` on each when no active
  ## borrowers (`gActiveBorrowers > 0`) are pinned and `hasPythonThreadState()` is true.
  if gDeferredQueueInitState.load(moAcquire) != 2'i32:
    return 0
  if gActiveBorrowers.load(moAcquire) > 0:
    return 0
  if Py_IsInitialized() == 0 or PyGILState_Check() == 0:
    return 0
  var drained = 0
  var rawItem: pointer = nil
  while popDeferredDecRef(rawItem):
    if not rawItem.isNil:
      Py_DecRef(cast[PyObjectPtr](rawItem))
      inc drained
  return drained

proc drainDeferredDecRefs*(): int {.inline, discardable, gcsafe, raises: [].} =
  flushDeferredDecRefs()

proc flushDeferredDecRefsCAbi() {.cdecl, gcsafe, raises: [].} =
  discard flushDeferredDecRefs()

# Register the deferred flush hook with lifecycle so every naganim_init_runtime /
# naganim_shutdown_runtime / boundary entry automatically drains queued DecRefs.
gDeferredFlushHook = flushDeferredDecRefsCAbi

proc deferredDecRefPendingCount*(): int {.inline, gcsafe, raises: [].} =
  gDeferredPendingCount.load(moAcquire)

proc naganim_flush_deferred_decrefs*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cint(flushDeferredDecRefs())

proc naganim_deferred_decref_count*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
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
  pyRawRefCount(x.raw)
