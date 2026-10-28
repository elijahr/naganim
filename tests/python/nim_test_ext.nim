## Real Nim Extension Module Compiled and Loaded by `pytest` in Both CFFI and ABI3 Modes.

import std/[options, tables, atomics]
import lockfree/taskpool
import ../../src/phyne

var gLastPinnedBuf*: PinnedBuffer[byte]

proc add_ints*(a: int64, b: int64): int64 {.exportpy.} =
  ## Adds two 64-bit integers and returns their sum.
  a + b

proc scale_float*(x: float64, factor: float64): float64 {.exportpy.} =
  ## Multiplies two 64-bit floats.
  x * factor

proc greet*(name: string): string {.exportpy.} =
  ## Formats a greeting string.
  "Hello from Nim, " & name & "!"

proc negate_bool*(flag: bool): bool {.exportpy.} =
  ## Negates a boolean value.
  not flag

proc reverse_seq*(items: seq[int64]): seq[int64] {.exportpy.} =
  ## Reverses a sequence of 64-bit integers.
  result = newSeq[int64](items.len)
  for i in 0 ..< items.len:
    result[i] = items[items.len - 1 - i]

proc lookup_or_none*(present: bool, val: int64): Option[int64] {.exportpy.} =
  ## Returns `some(val)` when `present` is true, or `none(int64)` otherwise.
  if present:
    return some(val)
  else:
    return none(int64)

proc merge_counts*(tbl: Table[string, int64], bonus: int64): Table[string, int64] {.exportpy.} =
  ## Adds `bonus` to every entry in `tbl`.
  result = initTable[string, int64]()
  for k, v in tbl.pairs:
    result[k] = v + bonus

proc swap_pair*(pair: (int64, string)): (string, int64) {.exportpy.} =
  ## Swaps a 2-tuple of `(int64, string)` into `(string, int64)`.
  (pair[1], pair[0])

proc make_pinned_bytes*(n: int64): PinnedBuffer[byte] {.exportpy.} =
  ## Allocates a zero-copy `PinnedBuffer[byte]` of length `n` initialized to `1..n`.
  if n < 0:
    raise newException(ValueError, "make_pinned_bytes length cannot be negative")
  gLastPinnedBuf = newPinnedBuffer[byte](int(n))
  for i in 0 ..< int(n):
    gLastPinnedBuf.writeAt(i, byte((i + 1) and 0xFF))
  return gLastPinnedBuf

proc sum_pinned_last*(): int64 {.exportpy.} =
  ## Sums the bytes of `gLastPinnedBuf`, proving zero-copy in-place mutations from Python.
  result = 0
  for i in 0 ..< gLastPinnedBuf.len:
    result += int64(gLastPinnedBuf[i])

proc last_pinned_export_count*(): int64 {.exportpy.} =
  ## Returns the current active exportCount on `gLastPinnedBuf`.
  int64(gLastPinnedBuf.exportCount)

proc trigger_scoped_resize_defect*(): int64 {.exportpy.} =
  ## Negative control: exports a ScopedSeqBuffer and attempts to resize it while exported.
  let sbuf = newScopedSeqBuffer([10'i64, 20'i64])
  sbuf.acquireExport()
  defer: sbuf.releaseExport()
  sbuf.add(30'i64)
  return int64(sbuf.len)

proc fail_with_value_error*(msg: string): int64 {.exportpy.} =
  ## Negative control: raises a Nim ValueError across the language boundary.
  raise newException(ValueError, msg)

proc fail_with_defect*(): int64 {.exportpy.} =
  ## Negative control: raises a Nim IndexDefect across the language boundary.
  raise newException(IndexDefect, "deliberate bounds defect")

var gExtWorkerDropDone: Atomic[int]

proc workerDestroyStolenPyObj(arg: pointer) {.nimcall, gcsafe.} =
  block:
    var stolenObj = fromStolenPointer(arg)
    discard stolenObj
  discard gExtWorkerDropDone.fetchAdd(1, moRelease)

proc spawn_threaded_pyobj_drop*(obj: PyObj, copies: int64): int64 {.exportpy.} =
  ## Clones `obj` `copies` times, transfers ownership to non-Python `TaskPool`
  ## worker threads, waits for worker destruction (which enqueues all `copies`
  ## into `gDeferredDecRefQueue`), and returns `deferredDecRefPendingCount()`
  ## BEFORE flushing so Python can verify deferred queueing and subsequent flush.
  gExtWorkerDropDone.store(0, moRelease)
  var pool = initTaskPool(4)
  for _ in 0 ..< int(copies):
    var clone = obj
    let rawPtr = stealToPointer(clone)
    pool.spawn(workerDestroyStolenPyObj, rawPtr)
  while gExtWorkerDropDone.load(moAcquire) < int(copies):
    cpuRelax()
  pool.sync()
  pool.shutdown(wait = true)
  return int64(deferredDecRefPendingCount())

proc flush_pending_decrefs*(): int64 {.exportpy.} =
  ## Explicitly flushes `gDeferredDecRefQueue` on the Python thread and returns
  ## the number of decremented `PyObject*` references.
  int64(flushDeferredDecRefs())

phyneInitModule("nim_test_ext", "Live Nim test extension for phyne pytest suite")
