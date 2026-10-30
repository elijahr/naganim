## Comprehensive Nim Test Suite for `naganim`.
##
## Exercises all core subsystems with structural equality assertions and
## negative controls:
## 1. Runtime initialization, idempotency & thread-local error firewalls
## 2. `PyObj` ORC lifecycle (`=destroy`, `=copy`, `=sink`) & pointer stealing
## 3. Wait-free deferred `Py_DecRef` queue (`BQueue128` + `TreiberStack`) from
##    real non-Python `lockfree` `TaskPool` worker threads
## 4. Bidirectional type marshaling (`toPy` / `fromPy`) & negative controls
## 5. Two-tier zero-copy Buffer Protocol (`PinnedBuffer`, `ScopedSeqBuffer`, PEP 3118)
## 6. Dual-target `{.exportpy.}` C-ABI & `abi3` wrappers + IR JSON generation
## 7. Lock-free `NaganimAsyncBridge` + OS pipe wakeup + `TaskPool` offloading

import std/[unittest, options, tables, strutils, atomics]
import lockfree/taskpool
import ../../src/naganim

# Ensure embedded CPython runtime is initialized for standalone Nim tests
if Py_IsInitialized() == 0:
  Py_InitializeEx(0)
discard naganim_init_runtime()

# Sample exported procs to test {.exportpy.} and IR metadata
proc exportedAdd*(a: int64, b: int64): int64 {.exportpy.} =
  ## Adds two 64-bit integers.
  a + b

proc exportedGreet*(name: string): string {.exportpy.} =
  ## Greets a user by name.
  "Hello, " & name & "!"

proc exportedReverseList*(xs: seq[int64]): seq[int64] {.exportpy.} =
  ## Reverses a sequence of integers.
  result = newSeq[int64](xs.len)
  for i in 0 ..< xs.len:
    result[i] = xs[xs.len - 1 - i]

proc exportedWillFail*(x: int64): int64 {.exportpy.} =
  if x < 0:
    raise newException(ValueError, "negative input disallowed: " & $x)
  if x == 999:
    raise newException(IndexDefect, "simulated defect on 999")
  return x * 2

naganimInitModule("naganim_nim_test_mod", "Test module for naganim")

var gWorkerDropDoneCount: Atomic[int]

proc nonPythonWorkerDropPyObj(arg: pointer) {.nimcall, gcsafe.} =
  # Reconstruct stolen PyObj on a non-Python TaskPool worker thread.
  # When `localObj` goes out of scope at the end of this block, `=destroy`
  # detects `hasPythonThreadState() == false` and enqueues `raw` into
  # `gDeferredDecRefQueue` without touching the GIL!
  block:
    var localObj = fromStolenPointer(arg)
    discard localObj
  discard gWorkerDropDoneCount.fetchAdd(1, moRelease)

suite "1. Runtime Lifecycle & Exception Firewalls":
  test "naganim_init_runtime is idempotent and thread-local error state round-trips":
    check naganim_init_runtime() == 0
    check naganim_init_runtime() == 0
    naganim_clear_error()
    check naganim_last_error() == nil

    naganim_set_last_error("custom error 42")
    check $naganim_last_error() == "custom error 42"
    naganim_clear_error()
    check naganim_last_error() == nil
    check naganim_shutdown_runtime() == 0

  test "cAbiBoundary catches CatchableError and Defect without unwinding":
    let rcOk = cAbiBoundary:
      discard 1 + 1
    check rcOk == 0
    check naganim_last_error() == nil

    let rcErr = cAbiBoundary:
      raise newException(ValueError, "bad value")
    check rcErr == -1
    check $naganim_last_error() == "ValueError: bad value"

    let rcDefect = cAbiBoundary:
      raise newException(IndexDefect, "out of bounds")
    check rcDefect == -2
    check $naganim_last_error() == "IndexDefect: out of bounds"
    naganim_clear_error()

suite "2. PyObj ORC Reference Counting & Wait-Free Deferred DecRef Queue":
  test "PyObj copy, sink, and stealToPointer maintain exact CPython ob_refcnt":
    # Create a unique heap-allocated Python list so it is not an immortal interned int
    let rawList = PyList_New(0)
    check rawList != nil
    let baseRc = int(rawList[].ob_refcnt)
    check baseRc == 1

    block:
      var obj1 = initPyObj(rawList, borrowed = true)
      check obj1.refCount == baseRc + 1

      var obj2 = obj1 # triggers `=copy`
      check obj1.refCount == baseRc + 2
      check obj2.refCount == baseRc + 2

      let stolenPtr = stealToPointer(obj2)
      check obj2.isNil
      # Stealing does NOT decrement refcount
      check int(rawList[].ob_refcnt) == baseRc + 2

      var obj3 = fromStolenPointer(stolenPtr)
      check obj3.refCount == baseRc + 2
    # Both obj1 and obj3 destroyed at block exit on Python thread
    check int(rawList[].ob_refcnt) == baseRc
    Py_DecRef(rawList)

  test "Real non-Python TaskPool worker threads enqueue to gDeferredDecRefQueue and drain cleanly":
    discard flushDeferredDecRefs()
    check deferredDecRefPendingCount() == 0

    let targetList = PyList_New(0)
    check targetList != nil
    let initialRc = int(targetList[].ob_refcnt)
    check initialRc == 1

    const numTasks = 32
    gWorkerDropDoneCount.store(0, moRelease)
    var pool = initTaskPool(4)

    for _ in 0 ..< numTasks:
      var holder = initPyObj(targetList, borrowed = true)
      let rawStolen = stealToPointer(holder)
      pool.spawn(nonPythonWorkerDropPyObj, rawStolen)

    while gWorkerDropDoneCount.load(moAcquire) < numTasks:
      cpuRelax()
    pool.sync()
    pool.shutdown(wait = true)

    # All 32 worker threads lacked a Python thread state, so all 32 decrements
    # must be sitting in the wait-free deferred queue, and targetList's refcount
    # must still be initialRc + 32!
    check deferredDecRefPendingCount() == numTasks
    check int(targetList[].ob_refcnt) == initialRc + numTasks

    # Now drain on the main Python thread
    let drained = flushDeferredDecRefs()
    check drained == numTasks
    check deferredDecRefPendingCount() == 0
    check int(targetList[].ob_refcnt) == initialRc
    Py_DecRef(targetList)

  test "Overflow beyond BQueue128 capacity spills into TreiberStack without dropping refs":
    discard flushDeferredDecRefs()
    let targetDict = PyDict_New()
    let initialRc = int(targetDict[].ob_refcnt)
    const totalRefs = 5000 # Exceeds 4096 ring buffer capacity

    gForceDeferredDecRef.store(true, moRelease)
    for _ in 0 ..< totalRefs:
      var tmp = initPyObj(targetDict, borrowed = true)
      discard tmp
    gForceDeferredDecRef.store(false, moRelease)

    check deferredDecRefPendingCount() == totalRefs
    check int(targetDict[].ob_refcnt) == initialRc + totalRefs

    let drained = flushDeferredDecRefs()
    check drained == totalRefs
    check deferredDecRefPendingCount() == 0
    check int(targetDict[].ob_refcnt) == initialRc
    Py_DecRef(targetDict)

suite "3. Bidirectional Type Marshaling & Negative Controls":
  test "Round-trip primitives, strings, bytes, seq, Option, Table, and tuples":
    let bTrue = toPy(true)
    let bFalse = toPy(false)
    check fromPy(bTrue, bool) == true
    check fromPy(bFalse, bool) == false

    let iVal = toPy(-9876543210'i64)
    check fromPy(iVal, int64) == -9876543210'i64

    let uVal = toPy(123456789012345'u64)
    check fromPy(uVal, uint64) == 123456789012345'u64

    let fVal = toPy(3.141592653589793)
    check fromPy(fVal, float64) == 3.141592653589793

    let sVal = toPy("naganim 🚀 unicode string")
    check fromPy(sVal, string) == "naganim 🚀 unicode string"

    let emptyStr = toPy("")
    check fromPy(emptyStr, string) == ""

    let bytesIn: seq[byte] = @[byte(0), byte(127), byte(255), byte(42)]
    let bytesPy = toPy(bytesIn)
    check fromPy(bytesPy, seq[byte]) == bytesIn

    let seqIn = @[10'i64, 20'i64, 30'i64, -40'i64]
    let seqPy = toPy(seqIn)
    check fromPy(seqPy, seq[int64]) == seqIn

    let optSome = toPy(some("present"))
    let optNone = toPy(none(string))
    check fromPy(optSome, Option[string]) == some("present")
    check fromPy(optNone, Option[string]) == none(string)

    var tblIn = initTable[string, int64]()
    tblIn["alpha"] = 1
    tblIn["beta"] = 2
    let tblPy = toPy(tblIn)
    let tblOut = fromPy(tblPy, Table[string, int64])
    check tblOut.len == 2
    check tblOut["alpha"] == 1
    check tblOut["beta"] == 2

    let tupIn = (42'i64, "answer", true)
    let tupPy = toPy(tupIn)
    check fromPy(tupPy, (int64, string, bool)) == (42'i64, "answer", true)

  test "Negative controls: type mismatches, bool-as-int rejection, arity errors, overflow":
    let pyStr = toPy("not an int")
    expect(NaganimConversionError):
      discard fromPy(pyStr, int64)

    let pyBool = toPy(true)
    expect(NaganimConversionError):
      discard fromPy(pyBool, int64)
    expect(NaganimConversionError):
      discard fromPy(pyBool, uint64)
    expect(NaganimConversionError):
      discard fromPy(pyBool, float64)

    let pyInt = toPy(1000'i64)
    expect(NaganimConversionError):
      discard fromPy(pyInt, bool)
    expect(NaganimConversionError):
      discard fromPy(pyInt, int8) # 1000 overflows int8

    let pyTup2 = toPy((1'i64, 2'i64))
    expect(NaganimConversionError):
      discard fromPy(pyTup2, (int64, int64, int64))

  test "Calling Python standard library modules (math, json) from Nim":
    let mathMod = pyImport("math")
    let sqrtFn = mathMod.getAttr("sqrt")
    let resObj = callPy(sqrtFn, toPy(144.0))
    check fromPy(resObj, float64) == 12.0

    let jsonMod = pyImport("json")
    let dumpsFn = jsonMod.getAttr("dumps")
    var d = initTable[string, int64]()
    d["k"] = 99
    let dumped = callPy(dumpsFn, toPy(d))
    check fromPy(dumped, string) == "{\"k\": 99}"

suite "4. Two-Tier Zero-Copy Buffer Protocol (PinnedBuffer & ScopedSeqBuffer)":
  test "PinnedBuffer zero-copy C-ABI view and PEP 3118 memoryview export tracking":
    var pbuf = newPinnedBufferFromOpenArray([10'i64, 20'i64, 30'i64, 40'i64])
    check pbuf.len == 4
    check pbuf.exportCount == 0
    check pbuf[2] == 30'i64

    var cView = pbuf.toBufView()
    check pbuf.exportCount == 1
    check int(cView.len) == 4 * sizeof(int64)
    check int(cView.itemsize) == sizeof(int64)
    naganim_buf_release(addr cView)
    check pbuf.exportCount == 0

    # Export as PEP 3118 Python memoryview and mutate through Python memoryview
    let mvObj = pbuf.toPyMemoryView()
    check pbuf.exportCount == 1
    let releaseMethod = mvObj.getAttr("release")
    discard callPy(releaseMethod)
    check pbuf.exportCount == 0

  test "ScopedSeqBuffer raises BufferExportedDefect on resize while exported":
    let sbuf = newScopedSeqBuffer([1'i64, 2'i64, 3'i64])
    check sbuf.len == 3
    sbuf.add(4'i64)
    check sbuf.toSeq() == @[1'i64, 2'i64, 3'i64, 4'i64]

    sbuf.acquireExport()
    check sbuf.exportCount == 1

    expect(BufferExportedDefect):
      sbuf.add(5'i64)

    expect(BufferExportedDefect):
      sbuf.setLen(2)

    sbuf.releaseExport()
    check sbuf.exportCount == 0
    sbuf.add(5'i64)
    check sbuf.toSeq() == @[1'i64, 2'i64, 3'i64, 4'i64, 5'i64]

    # Export ScopedSeqBuffer directly via toPyMemoryView / toPyRaw and verify exportCount & resize guard
    let smv = sbuf.toPyMemoryView()
    check sbuf.exportCount == 1
    expect(BufferExportedDefect):
      sbuf.add(6'i64)
    let smvRelease = smv.getAttr("release")
    discard callPy(smvRelease)
    check sbuf.exportCount == 0
    sbuf.add(6'i64)
    check sbuf.toSeq() == @[1'i64, 2'i64, 3'i64, 4'i64, 5'i64, 6'i64]

    # Verify mapTypeToPyStub top-level comma splitting for nested Table types
    const nestedDictStub = mapTypeToPyStub("Table[string, Table[string, int64]]")
    const tupleValDictStub = mapTypeToPyStub("Table[string, (int64, string)]")
    check nestedDictStub == "dict[str, dict[str, int]]"
    check tupleValDictStub == "dict[str, Any]"

suite "5. Dual-Target {.exportpy.} Wrappers & IR Metadata":
  test "C-ABI and PyCFunction wrappers execute and enforce negative controls":
    var outAdd: int64 = 0
    check naganim_c_exportedAdd(17, 25, addr outAdd) == 0
    check outAdd == 42

    var outStr: cstring = nil
    check naganim_c_exportedGreet("Nim", addr outStr) == 0
    check $outStr == "Hello, Nim!"

    # Negative controls on naganim_c_exportedWillFail
    var outFail: int64 = 0
    check naganim_c_exportedWillFail(-5, addr outFail) == -1
    check $naganim_last_error() == "ValueError: negative input disallowed: -5"

    check naganim_c_exportedWillFail(999, addr outFail) == -2
    check $naganim_last_error() == "IndexDefect: simulated defect on 999"
    naganim_clear_error()

    # PyCFunction wrapper test
    let argsTup = toPy((100'i64, 23'i64))
    let pyRes = naganim_py_exportedAdd(nil, argsTup.raw)
    check pyRes != nil
    check fromPyRaw(pyRes, int64) == 123
    Py_DecRef(pyRes)

    # Arity mismatch negative control on PyCFunction
    let badArgs = toPy((100'i64,))
    let badRes = naganim_py_exportedAdd(nil, badArgs.raw)
    check badRes == nil
    check PyErr_Occurred() != nil
    PyErr_Clear()

    let irJson = $naganim_module_ir_json()
    check irJson.startsWith("{\n  \"module\": \"naganim_nim_test_mod\"")

suite "6. Lock-Free NaganimAsyncBridge & TaskPool Offloading":
  test "NaganimAsyncBridge offloads parallel sum of squares to TaskPool and signals wakeup pipe":
    let bridge = naganim_async_bridge_create(4)
    check bridge != nil
    let rfd = naganim_async_bridge_read_fd(bridge)
    check rfd >= 0

    check naganim_async_submit_compute(bridge, 101'u64, 1, 1, 10) == 0
    # Wait for TaskPool completion
    let bPtr = cast[ptr NaganimAsyncBridge](bridge)
    bPtr.pool.sync()

    let drainedBytes = naganim_async_drain_wakeup(bridge)
    check drainedBytes == 1

    var futId: uint64 = 0
    var status: cint = -99
    var intVal: int64 = 0
    var floatVal: float64 = 0.0
    var strVal: cstring = nil
    check naganim_async_pop_completion(bridge, addr futId, addr status, addr intVal, addr floatVal, addr strVal) == 1
    check futId == 101'u64
    check status == 0
    check intVal == 385'i64 # 1^2 + 2^2 + ... + 10^2 = 385

    naganim_async_bridge_destroy(bridge)
