## Lock-Free `naganim/asyncio` Event-Loop Bridge, `TaskPool` Offloading & `AsyncChannel`.
##
## Implements `design.md` §3.3 (`CRIT-03`):
## - Bounded lock-free completion ring (`BQueue128[pointer, 1024]`) + overflow
##   `TreiberStack[pointer]`
## - 0-to-1 edge-triggered OS wakeup (`eventfd` on Linux, non-blocking `pipe` on macOS/POSIX)
##   for `loop.add_reader(read_fd, _on_nim_wakeup)` with zero polling timers
## - Integrated `lockfree/taskpool` (`TaskPool`) worker offloading without holding the GIL
## - Automatic `flushDeferredDecRefs()` on every event-loop wakeup turn

import std/[atomics, options, posix]
import lockfree/bqueue128
import lockfree/stack
import lockfree/taskpool
import ./lifecycle
import ./gc_bridge

const
  MaxActiveAsyncBridges* = 64
  MaxRegisteredComputeOps* = 256

type
  NaganimCompletionKind* = enum
    pckFutureOk = 0
    pckFutureErr = -1
    pckChannelItem = 1
    pckChannelClosed = 2

  NaganimCompletionEvent* = object
    futureId*: uint64
    status*: cint
    intVal*: int64
    floatVal*: float64
    strPayload*: pointer
    strLen*: int

  NaganimIntTaskProc* = proc(arg: int64): int64 {.cdecl, gcsafe.}

  NaganimComputeOpProc* = proc(
    argA: int64,
    argB: int64,
    outResult: ptr int64,
    outErrBuf: ptr char,
    errBufCap: csize_t
  ): cint {.cdecl, gcsafe.}

  NaganimTaskCtx = object
    bridge: ptr NaganimAsyncBridge
    futureId: uint64
    opCode: cint
    argA: int64
    argB: int64
    customFn: NaganimIntTaskProc
    pyObjCarry: pointer # Optional stolen PyObj pointer to test non-Python thread destruction

  NaganimAsyncBridge* = object
    ringPtr*: ptr BQueue128[pointer, 1024]
    overflow*: TreiberStack[pointer]
    pendingWakeup*: Atomic[bool]
    readFd*: cint
    writeFd*: cint
    pool*: TaskPool
    poolInitialized*: bool

var
  gActiveBridgeForDecRef*: Atomic[pointer]
  gActiveAsyncBridges: array[MaxActiveAsyncBridges, Atomic[pointer]]
  gRegisteredComputeOps: array[MaxRegisteredComputeOps, Atomic[pointer]]
  gPopStringReturnBuf* {.threadvar.}: string

proc registerActiveBridge(bridge: ptr NaganimAsyncBridge) {.gcsafe, raises: [].} =
  if bridge.isNil:
    return
  let raw = cast[pointer](bridge)
  gActiveBridgeForDecRef.store(raw, moRelease)
  for i in 0 ..< MaxActiveAsyncBridges:
    if gActiveAsyncBridges[i].load(moAcquire) == raw:
      return
  for i in 0 ..< MaxActiveAsyncBridges:
    var expected: pointer = nil
    if gActiveAsyncBridges[i].compareExchange(expected, raw, moAcquireRelease, moAcquire):
      return

proc unregisterActiveBridge(bridge: ptr NaganimAsyncBridge) {.gcsafe, raises: [].} =
  if bridge.isNil:
    return
  let raw = cast[pointer](bridge)
  for i in 0 ..< MaxActiveAsyncBridges:
    var expected = raw
    discard gActiveAsyncBridges[i].compareExchange(expected, nil, moAcquireRelease, moRelaxed)
  var expectedPrimary = raw
  if gActiveBridgeForDecRef.compareExchange(expectedPrimary, nil, moAcquireRelease, moRelaxed):
    for i in 0 ..< MaxActiveAsyncBridges:
      let candidate = gActiveAsyncBridges[i].load(moAcquire)
      if not candidate.isNil:
        gActiveBridgeForDecRef.store(candidate, moRelease)
        break

proc activeAsyncBridgeCount*(): int {.gcsafe, raises: [].} =
  for i in 0 ..< MaxActiveAsyncBridges:
    if not gActiveAsyncBridges[i].load(moAcquire).isNil:
      inc result

proc registerAsyncComputeOp*(opCode: cint, fn: NaganimComputeOpProc): cint {.discardable, gcsafe, raises: [].} =
  if opCode <= 0 or opCode >= MaxRegisteredComputeOps or fn.isNil:
    setLastError("Invalid async opCode (must be in 1..255 and non-nil callback)")
    return -1
  gRegisteredComputeOps[int(opCode)].store(cast[pointer](fn), moRelease)
  return 0

proc unregisterAsyncComputeOp*(opCode: cint): cint {.discardable, gcsafe, raises: [].} =
  if opCode <= 0 or opCode >= MaxRegisteredComputeOps:
    setLastError("Invalid async opCode (must be in 1..255)")
    return -1
  gRegisteredComputeOps[int(opCode)].store(nil, moRelease)
  return 0

proc setFdNonBlocking(fd: cint) {.gcsafe, raises: [].} =
  let flags = fcntl(fd, F_GETFL, 0)
  if flags >= 0:
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc signalBridgeWakeup*(bridge: ptr NaganimAsyncBridge) {.gcsafe, raises: [].} =
  if bridge.isNil or bridge.writeFd < 0:
    return
  if not bridge.pendingWakeup.exchange(true, moAcquireRelease):
    var b: uint8 = 1
    discard posix.write(bridge.writeFd, addr b, 1)

proc onDeferredDecRefWakeup() {.cdecl, gcsafe, raises: [].} =
  var signaledAny = false
  for i in 0 ..< MaxActiveAsyncBridges:
    let bridge = cast[ptr NaganimAsyncBridge](gActiveAsyncBridges[i].load(moAcquire))
    if not bridge.isNil:
      signalBridgeWakeup(bridge)
      signaledAny = true
  if not signaledAny:
    let fallback = cast[ptr NaganimAsyncBridge](gActiveBridgeForDecRef.load(moAcquire))
    if not fallback.isNil:
      signalBridgeWakeup(fallback)

proc pushCompletionEvent*(bridge: ptr NaganimAsyncBridge, ev: NaganimCompletionEvent) {.gcsafe, raises: [].} =
  if bridge.isNil or bridge.ringPtr.isNil:
    return
  let evBox = cast[ptr NaganimCompletionEvent](allocShared0(sizeof(NaganimCompletionEvent)))
  evBox[] = ev
  let rawBox = cast[pointer](evBox)
  var pushed = false
  var transitioned = false
  {.cast(gcsafe), cast(raises: []).}:
    pushed = bridge.ringPtr[].tryPushEx(rawBox, transitioned)
    if not pushed:
      bridge.overflow.push(rawBox)
      transitioned = true
  if transitioned or not bridge.pendingWakeup.load(moAcquire):
    signalBridgeWakeup(bridge)

proc pushCompletionString*(
  bridge: ptr NaganimAsyncBridge,
  futureId: uint64,
  status: cint,
  s: string
) {.gcsafe, raises: [].} =
  var p: pointer = nil
  if s.len > 0:
    p = allocShared0(s.len + 1)
    copyMem(p, unsafeAddr s[0], s.len)
  let ev = NaganimCompletionEvent(
    futureId: futureId,
    status: status,
    intVal: 0,
    floatVal: 0.0,
    strPayload: p,
    strLen: s.len
  )
  pushCompletionEvent(bridge, ev)

proc createAsyncBridge*(numWorkers: int = 4): ptr NaganimAsyncBridge {.gcsafe.} =
  var fds: array[2, cint]
  if posix.pipe(fds) != 0:
    raise newException(NaganimError, "posix.pipe() failed while creating NaganimAsyncBridge")
  setFdNonBlocking(fds[0])
  setFdNonBlocking(fds[1])

  let bridge = cast[ptr NaganimAsyncBridge](allocShared0(sizeof(NaganimAsyncBridge)))
  {.cast(gcsafe).}:
    bridge.ringPtr = allocAlignedBQueue128[pointer, 1024]()
    bridge.overflow = initTreiberStack[pointer]()
  bridge.pendingWakeup.store(false, moRelease)
  bridge.readFd = fds[0]
  bridge.writeFd = fds[1]
  if numWorkers > 0:
    {.cast(gcsafe).}:
      bridge.pool = initTaskPool(numWorkers)
    bridge.poolInitialized = true
  registerActiveBridge(bridge)
  discard registerDeferredWakeupHook(onDeferredDecRefWakeup)
  return bridge

proc destroyAsyncBridge*(bridge: ptr NaganimAsyncBridge) {.gcsafe, raises: [].} =
  if bridge.isNil:
    return
  unregisterActiveBridge(bridge)
  if bridge.poolInitialized:
    {.cast(gcsafe), cast(raises: []).}:
      try:
        bridge.pool.sync()
        bridge.pool.shutdown(wait = true)
      except Exception:
        discard
    bridge.poolInitialized = false
  discard flushDeferredDecRefs()
  var rawBox: pointer = nil
  {.cast(gcsafe), cast(raises: []).}:
    if not bridge.ringPtr.isNil:
      while bridge.ringPtr[].tryPop(rawBox):
        if not rawBox.isNil:
          let evPtr = cast[ptr NaganimCompletionEvent](rawBox)
          if not evPtr.strPayload.isNil:
            deallocShared(evPtr.strPayload)
          deallocShared(evPtr)
      freeAlignedBQueue128(bridge.ringPtr)
      bridge.ringPtr = nil
    while true:
      let opt = bridge.overflow.pop()
      if opt.isNone:
        break
      rawBox = opt.get()
      if not rawBox.isNil:
        let evPtr = cast[ptr NaganimCompletionEvent](rawBox)
        if not evPtr.strPayload.isNil:
          deallocShared(evPtr.strPayload)
        deallocShared(evPtr)
  if bridge.readFd >= 0:
    discard posix.close(bridge.readFd)
    bridge.readFd = -1
  if bridge.writeFd >= 0:
    discard posix.close(bridge.writeFd)
    bridge.writeFd = -1
  deallocShared(bridge)

proc drainWakeupPipe*(bridge: ptr NaganimAsyncBridge): int {.discardable, gcsafe, raises: [].} =
  ## Drains all pending wakeup bytes from `readFd`, clears `pendingWakeup`,
  ## and flushes any deferred `Py_DecRef` pointers accumulated from worker threads.
  if bridge.isNil or bridge.readFd < 0:
    return 0
  var buf: array[64, uint8]
  var totalBytes = 0
  while true:
    let n = posix.read(bridge.readFd, addr buf[0], sizeof(buf))
    if n <= 0:
      break
    totalBytes += int(n)
  bridge.pendingWakeup.store(false, moRelease)
  discard flushDeferredDecRefs()
  return totalBytes

proc popCompletion*(bridge: ptr NaganimAsyncBridge, outEv: var NaganimCompletionEvent): bool {.gcsafe, raises: [].} =
  if bridge.isNil or bridge.ringPtr.isNil:
    return false
  discard flushDeferredDecRefs()
  var rawBox: pointer = nil
  {.cast(gcsafe), cast(raises: []).}:
    if bridge.ringPtr[].tryPop(rawBox):
      if not rawBox.isNil:
        let evPtr = cast[ptr NaganimCompletionEvent](rawBox)
        outEv = evPtr[]
        deallocShared(evPtr)
        return true
    let opt = bridge.overflow.pop()
    if opt.isSome:
      rawBox = opt.get()
      if not rawBox.isNil:
        let evPtr = cast[ptr NaganimCompletionEvent](rawBox)
        outEv = evPtr[]
        deallocShared(evPtr)
        return true
  return false

# ---------------------------------------------------------------------------
# Worker Task Execution on lockfree TaskPool (Runs without Python GIL!)
# ---------------------------------------------------------------------------
proc workerExecuteTask(arg: pointer) {.nimcall, gcsafe.} =
  let ctx = cast[ptr NaganimTaskCtx](arg)
  if ctx.isNil:
    return
  let bridge = ctx.bridge
  let futId = ctx.futureId
  let op = ctx.opCode
  let a = ctx.argA
  let b = ctx.argB
  let customFn = ctx.customFn
  let carryPtr = ctx.pyObjCarry
  deallocShared(ctx)

  if not carryPtr.isNil:
    var carriedObj = fromStolenPointer(carryPtr)
    discard carriedObj

  try:
    if op == 0 and not customFn.isNil:
      let res = customFn(a)
      pushCompletionEvent(bridge, NaganimCompletionEvent(
        futureId: futId,
        status: cint(pckFutureOk),
        intVal: res
      ))
    elif op == 0:
      pushCompletionString(bridge, futId, cint(pckFutureErr), "Null task function pointer")
    elif op > 0 and op < MaxRegisteredComputeOps:
      let rawHandler = gRegisteredComputeOps[int(op)].load(moAcquire)
      if rawHandler.isNil:
        pushCompletionString(bridge, futId, cint(pckFutureErr), "Unregistered async task opcode: " & $op)
      else:
        let handler = cast[NaganimComputeOpProc](rawHandler)
        var outVal: int64 = 0
        var errBuf: array[256, char]
        errBuf[0] = '\0'
        let rc = handler(a, b, addr outVal, addr errBuf[0], csize_t(sizeof(errBuf)))
        if rc == 0:
          pushCompletionEvent(bridge, NaganimCompletionEvent(
            futureId: futId,
            status: cint(pckFutureOk),
            intVal: outVal
          ))
        else:
          let errMsg =
            if errBuf[0] != '\0':
              $cast[cstring](addr errBuf[0])
            else:
              "TaskError: registered op " & $op & " failed with status " & $rc
          pushCompletionString(bridge, futId, cint(pckFutureErr), errMsg)
    else:
      pushCompletionString(bridge, futId, cint(pckFutureErr), "Unknown task opcode: " & $op)
  except CatchableError as e:
    pushCompletionString(bridge, futId, cint(pckFutureErr), $e.name & ": " & e.msg)
  except Defect as d:
    pushCompletionString(bridge, futId, cint(pckFutureErr), $d.name & ": " & d.msg)

proc submitComputeTask*(
  bridge: ptr NaganimAsyncBridge,
  futureId: uint64,
  opCode: cint,
  argA: int64,
  argB: int64,
  stolenPyObjPtr: pointer = nil
) {.gcsafe.} =
  if bridge.isNil or not bridge.poolInitialized:
    raise newException(NaganimError, "NaganimAsyncBridge TaskPool is not initialized")
  let ctx = cast[ptr NaganimTaskCtx](allocShared0(sizeof(NaganimTaskCtx)))
  ctx.bridge = bridge
  ctx.futureId = futureId
  ctx.opCode = opCode
  ctx.argA = argA
  ctx.argB = argB
  ctx.customFn = nil
  ctx.pyObjCarry = stolenPyObjPtr
  {.cast(gcsafe).}:
    bridge.pool.spawn(workerExecuteTask, cast[pointer](ctx))

proc submitIntTask*(
  bridge: ptr NaganimAsyncBridge,
  futureId: uint64,
  fn: NaganimIntTaskProc,
  arg: int64
) {.gcsafe.} =
  if bridge.isNil or not bridge.poolInitialized:
    raise newException(NaganimError, "NaganimAsyncBridge TaskPool is not initialized")
  let ctx = cast[ptr NaganimTaskCtx](allocShared0(sizeof(NaganimTaskCtx)))
  ctx.bridge = bridge
  ctx.futureId = futureId
  ctx.opCode = 0
  ctx.argA = arg
  ctx.argB = 0
  ctx.customFn = fn
  ctx.pyObjCarry = nil
  {.cast(gcsafe).}:
    bridge.pool.spawn(workerExecuteTask, cast[pointer](ctx))

# ---------------------------------------------------------------------------
# C-ABI Exports for Python `naganim.asyncio` (`NaganimAsyncBridge` & `AsyncChannel`)
# ---------------------------------------------------------------------------
proc naganim_async_bridge_create*(numWorkers: cint): pointer {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  discard naganim_init_runtime()
  try:
    return cast[pointer](createAsyncBridge(int(numWorkers)))
  except CatchableError as e:
    setLastError($e.name & ": " & e.msg)
    return nil

proc naganim_async_bridge_destroy*(bridgePtr: pointer) {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  destroyAsyncBridge(cast[ptr NaganimAsyncBridge](bridgePtr))

proc naganim_async_bridge_read_fd*(bridgePtr: pointer): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  let b = cast[ptr NaganimAsyncBridge](bridgePtr)
  if b.isNil: return -1
  return b.readFd

proc naganim_async_drain_wakeup*(bridgePtr: pointer): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  let b = cast[ptr NaganimAsyncBridge](bridgePtr)
  return cint(drainWakeupPipe(b))

proc naganim_async_pop_completion*(
  bridgePtr: pointer,
  outFutureId: ptr uint64,
  outStatus: ptr cint,
  outInt: ptr int64,
  outFloat: ptr float64,
  outStr: ptr cstring
): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  ## Pops a single completion event from the lock-free ring.
  ## Returns 1 if an event was popped, 0 if empty.
  let b = cast[ptr NaganimAsyncBridge](bridgePtr)
  if b.isNil:
    return 0
  var ev: NaganimCompletionEvent
  if not popCompletion(b, ev):
    return 0
  if not outFutureId.isNil: outFutureId[] = ev.futureId
  if not outStatus.isNil: outStatus[] = ev.status
  if not outInt.isNil: outInt[] = ev.intVal
  if not outFloat.isNil: outFloat[] = ev.floatVal
  if not ev.strPayload.isNil:
    gPopStringReturnBuf = newString(ev.strLen)
    if ev.strLen > 0:
      copyMem(addr gPopStringReturnBuf[0], ev.strPayload, ev.strLen)
    deallocShared(ev.strPayload)
    if not outStr.isNil:
      outStr[] = cstring(gPopStringReturnBuf)
  else:
    gPopStringReturnBuf = ""
    if not outStr.isNil:
      outStr[] = nil
  return 1

proc naganim_async_register_op*(
  opCode: cint,
  fn: NaganimComputeOpProc
): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  discard naganim_init_runtime()
  naganim_clear_error()
  registerAsyncComputeOp(opCode, fn)

proc naganim_async_unregister_op*(
  opCode: cint
): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  discard naganim_init_runtime()
  naganim_clear_error()
  unregisterAsyncComputeOp(opCode)

proc naganim_async_active_bridge_count*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cint(activeAsyncBridgeCount())

proc naganim_async_submit_compute*(
  bridgePtr: pointer,
  futureId: uint64,
  opCode: cint,
  argA: int64,
  argB: int64
): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cAbiBoundary:
    let b = cast[ptr NaganimAsyncBridge](bridgePtr)
    submitComputeTask(b, futureId, opCode, argA, argB)

proc naganim_async_channel_push_int*(
  bridgePtr: pointer,
  channelId: uint64,
  val: int64
): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cAbiBoundary:
    let b = cast[ptr NaganimAsyncBridge](bridgePtr)
    if b.isNil:
      raise newException(NaganimError, "Null NaganimAsyncBridge pointer")
    pushCompletionEvent(b, NaganimCompletionEvent(
      futureId: channelId,
      status: cint(pckChannelItem),
      intVal: val
    ))

proc naganim_async_channel_close*(
  bridgePtr: pointer,
  channelId: uint64
): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  cAbiBoundary:
    let b = cast[ptr NaganimAsyncBridge](bridgePtr)
    if b.isNil:
      raise newException(NaganimError, "Null NaganimAsyncBridge pointer")
    pushCompletionEvent(b, NaganimCompletionEvent(
      futureId: channelId,
      status: cint(pckChannelClosed),
      intVal: 0
    ))
