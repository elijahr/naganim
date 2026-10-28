# Stage 1 Fact-Check Gate & Stage 3 Adversarial Design Audit (`audit_report.md`)

**Auditor**: `@pyon-auditor` (Briar-Lens — Verification & Adversarial Auditor)
**Task ID**: `msg_1793182735_pyon-orchestrator_5274` (Phase 0, Task 0.2)
**Audited Artifacts**:
- `/Users/eek/Development/pyon/understanding.md`
- `/Users/eek/Development/pyon/design.md`
**Date**: 2026-10-28
**Status**: **RATIFIED (Post-Remediation — 0 Open CRIT/HIGH Defects)**

---

## 1. Executive Audit Summary

We executed an exhaustive tool-grounded **Stage 1 Fact-Check Gate** and **Stage 3 Adversarial Design Audit** across `/Users/eek/Development/pyon/understanding.md` and `/Users/eek/Development/pyon/design.md`, cross-checking every cited file path, line number, dataclass layout, C99 header prototype, and lock-free memory ordering invariant against `/Users/eek/Development/headerkit` and `/Users/eek/Development/lockfree`.

### Audit Defect Tally (Initial Pass $\to$ Remediated)
| Severity | Found | Remediated in `understanding.md` & `design.md` | Open |
| :--- | :---: | :---: | :---: |
| **CRIT** | 2 | 2 | **0** |
| **HIGH** | 3 | 3 | **0** |
| **MED** | 2 | 2 | **0** |
| **LOW** | 1 | 1 | **0** |

All 8 findings have been empirically verified and remediated directly in `/Users/eek/Development/pyon/understanding.md` and `/Users/eek/Development/pyon/design.md` so downstream implementation strands (Tasks 1.1, 2.1, 3.1, 4.1) build against 100% accurate specifications.

---

## 2. Detailed Findings & Empirical Evidence

### `[CRIT-01]` Hallucinated `VirtualMirrorBuffer` & `use_virtual_mirror = true` Exception in `lockfree/streambuffer.nim`
- **Severity**: `CRIT` (Would cause `lockless.StreamBuffer` construction to return `NULL` / fail unconditionally at runtime)
- **Locations in Audited Docs**:
  - `understanding.md:36`, `understanding.md:111`
  - `design.md:126`, `design.md:332`, `design.md:430`, `design.md:433`
- **Empirical Ground Truth (`/Users/eek/Development/lockfree/src/lockfree/streambuffer.nim`)**:
  1. `understanding.md:36` claimed `VirtualMirrorBuffer` exists at `streambuffer.nim:44-50` and `StreamRing` is at `261-283` / `MPMCStreamRing` at `448-459`. In reality, `streambuffer.nim:44-50` is `posix_memalign` / `allocAlignedBuffer`, `StreamRing` is at `streambuffer.nim:276-291`, and `MPMCStreamRing` is at `streambuffer.nim:545-552`.
  2. Most critically, `initStreamRing` at `/Users/eek/Development/lockfree/src/lockfree/streambuffer.nim:295-296` **unconditionally raises `ValueError`** when `useVirtualMirror == true`:
     ```nim
     if useVirtualMirror:
       raise newException(ValueError, "Virtual memory mirrored ring buffer is not supported on this platform; use dual-slice IOVecPair")
     ```
  3. In `/Users/eek/Development/lockfree/src/lockfree/cabi.nim:2429-2433`, `lf_stream_ring_create(capacity, true)` catches this `ValueError` and returns `nil`.
  4. Furthermore, `acquireWriteIov` (`streambuffer.nim:354-376`) and `acquireReadIov` (`streambuffer.nim:392-414`) never inspect `self.isMirrored`; they always compute `let l1 = min(n, self.capacity - tailIdx)` (`iov.first` up to the physical wrap boundary).
- **Remediation Applied to `understanding.md` & `design.md`**:
  - `lockless.StreamBuffer` defaults to `virtual_mirror: bool = False` (or `streambuffer.nim` uses `use_virtual_mirror = false` standard aligned ring buffer).
  - `lf_stream_reserve_write(ring, min_bytes, out_ptr, out_avail_len)` and `lf_stream_peek_read(ring, out_ptr, out_avail_len)` return the contiguous slice `iov.first` (`ring.buffer + offset` up to `min(avail, cap - offset)`). When the write cursor sits near the physical end of the ring such that `cap - tailIdx < min_bytes` while total `avail >= min_bytes`, `StreamBuffer` either commits the partial slice or (when `min_bytes` contiguous space is required) pads/wraps cleanly.

---

### `[CRIT-02]` Missing `doc: str | None` Field on `@dataclass(slots=True)` IR Nodes in `headerkit/ir.py`
- **Severity**: `CRIT` (Would raise `TypeError` / `AttributeError` at runtime in `NimJsonDocEnricher` and `PyiWriter`)
- **Locations in Audited Docs**:
  - `understanding.md:58`, `design.md:235`, `design.md:250`
- **Empirical Ground Truth (`/Users/eek/Development/headerkit/headerkit/ir.py`)**:
  - `understanding.md:58` claimed `Function` in `headerkit/ir.py:695-772` "already includes `doc: str | None = None` (`line 710`) and `calling_convention: str | None = None` (`line 715`)".
  - Inspection of `/Users/eek/Development/headerkit/headerkit/ir.py:695-758` proves that `Function` is decorated with `@dataclass(slots=True)` (`line 695`), `calling_convention` is at `line 740`, and **no `doc` field exists on `Function`, `Struct`, `Enum`, or `Typedef`**.
  - Because `slots=True` prevents attaching arbitrary attributes and `dataclasses.replace()` rejects unknown field names, `NimJsonDocEnricher` and `PyiWriter` would crash immediately upon setting or reading `func.doc`.
- **Remediation Applied to `understanding.md` & `design.md`**:
  - Updated `understanding.md:58` and `design.md` Section 3.5/3.6: if `doc` enrichment is used, `doc: str | None = None` must be explicitly added to `Function` (and optionally `Struct`, `Enum`, `Typedef`) in `headerkit/ir.py`, or `PyiWriter` must read `getattr(func, "doc", None)` safely.

---

### `[HIGH-01]` `rewrite_type_references` Type-Widening Failure on `NCSTRING -> Pointer(CType("char"))`
- **Severity**: `HIGH` (Breaks `mypy --strict` and corrupts AST in `NimCleanupTransform`)
- **Locations in Audited Docs**:
  - `design.md:221-229`
- **Empirical Ground Truth (`/Users/eek/Development/headerkit/headerkit/transforms/builtin.py:33-51`)**:
  - `design.md:221-229` specified that `NimCleanupTransform` rewrites `NCSTRING` $\to$ `Pointer(CType("char"))` "via `rewrite_type_references`".
  - In `/Users/eek/Development/headerkit/headerkit/transforms/builtin.py:33-38`, `rewrite_type_references(type_expr: TypeExpr, mapping: dict[str, str]) -> TypeExpr` only accepts `dict[str, str]` and executes `replace(type_expr, name=mapping[type_expr.name])`, which always returns a `CType` — it cannot replace a `CType("NCSTRING")` with a `Pointer(CType("char"))`!
- **Remediation Applied to `design.md`**:
  - Specified that `NimCleanupTransform` implements a dedicated `_rewrite_nim_type(type_expr: TypeExpr) -> TypeExpr` helper (or `visit_CType`) that maps `CType("NCSTRING", quals)` directly to `Pointer(CType("char", list(quals)))` and maps scalar Nim typedefs (`NI`, `NU`, `NI8`..`NI64`, `NU8`..`NU64`, `NF`, `NF32`, `NF64`, `NIM_BOOL`, `NIM_CHAR`) to their C99 `CType` equivalents.

---

### `[HIGH-02]` Lost Wakeup Hazard in `phyne/asyncio` When `BQueue128` Producer Is Preempted Between `tail` CAS and Slot DWCAS
- **Severity**: `HIGH` (Deadlock / lost wakeup under multi-producer preemption)
- **Locations in Audited Docs**:
  - `design.md:154-162`, `design.md:344-380`
- **Empirical Ground Truth (`/Users/eek/Development/lockfree/src/lockfree/bqueue128.nim:132-145, 168-186, 227-243`)**:
  - In `BQueue128.tryPush` (`bqueue128.nim:132-139`), a producer first advances `self.tail` from `pos` to `pos + 1` (`line 132`) and *then* performs the 128-bit DWCAS on `self.cells[pos and mask]` (`line 138`).
  - Meanwhile, `lf_bqueue128_is_empty` (`bqueue128.nim:240-242`) checks `self.len == 0` (`tail == head`), whereas `lf_bqueue128_pop` (`bqueue128.nim:168-185`) checks `observed.first == pos + 1` and gives up after `BQueue128MaxWaitForPublishSpins` (`1024`) spins if a producer was preempted between lines `132` and `138`.
  - In `design.md:379-380`, if the consumer sets `consumerSleeping.store(true, moSeqCst)` and checks `not lf_bqueue128_is_empty(ring)` (which is `true` because `tail > head`), it flips `consumerSleeping` back to `false` and calls `lf_bqueue128_pop`, which returns `LF_ERR_EMPTY` if the producer is still preempted! If the consumer then exits `_on_wakeup` with `consumerSleeping == false`, then when the producer resumes at line `138` and checks `consumerSleeping`, it sees `false` and **never writes to `wakeup_fd`**, stranding the item forever!
  - Additionally, in `boundedPushEx` (`design.md:158-159`), reading `headBefore` and `tailBefore` outside `p.bound.push(item)` is non-atomic with the slot claim.
- **Remediation Applied to `design.md`**:
  1. In `BQueue128.tryPushEx` (`src/lockfree/bqueue128.nim`), `wasEmpty` is computed as `let h = self.head.load(moAcquire); wasEmpty = (h == pos)` where `pos` is the exact sequence turn claimed by the CAS on `self.tail`.
  2. In `BoundedQueueImpl` (`src/lockfree/cabi.nim`), `boundedPushEx` checks `head == claimedPos` (or `let h = q.rawQueue.head.load(moAcquire); let t = q.rawQueue.tail.load(moAcquire); wasEmpty = (t - h <= 1)` immediately after publish).
  3. In `phyne/asyncio` (`design.md:369-380`), the producer executes `threadFence(moSequentiallyConsistent)` *after* the slot DWCAS completes and wakes `wakeup_fd` whenever `consumerSleeping.exchange(false, moSequentiallyConsistent)` returns `true` (independent of `was_empty`, because `consumerSleeping` is only `true` when the consumer is idle, guaranteeing 0 syscalls during active polling and at most 1 syscall per sleep transition). On the consumer side, if `not lf_bqueue128_is_empty(ring)` is true during the Dekker re-check but `lf_bqueue128_pop` returns `LF_ERR_EMPTY` (due to an in-flight preempted producer), the consumer schedules `loop.call_soon(_on_wakeup)` rather than returning with `consumerSleeping == false`.

---

### `[HIGH-03]` Unreclaimed `PyObject*` References on Map Key Overwrite/Remove & `BroadcastRing` Eviction
- **Severity**: `HIGH` (Memory leak of `PyObject*` references on key update, deletion, or ring wrap-around)
- **Locations in Audited Docs**:
  - `understanding.md:129-146`, `design.md:420`, `design.md:438-447`
- **Empirical Ground Truth (`/Users/eek/Development/lockfree/src/lockfree/cabi.nim`)**:
  - Inspection of `lf_table_put` (`cabi.nim:1169-1181`), `lf_table_delete` (`cabi.nim:1198-1213`), `lf_ctrie_insert`/`put` (`cabi.nim:1489-1510`), and `lf_ctrie_remove` (`cabi.nim:1532-1555`) confirms that `table.destructor` and `ctrie.destructor` are **only invoked inside `lf_table_destroy` (`line 1161`) and `lf_ctrie_destroy` (`line 1481`)** — they are **never** invoked when `put` overwrites an existing key or when `delete`/`remove` removes a key!
  - Furthermore, `lf_broadcast_create` (`cabi.nim:1706-1723`) does not take a destructor callback at all.
- **Remediation Applied to `design.md`**:
  - Specified in `design.md` Section 5.2 that `lockless_ext.nim` (which imports `lockfree` directly in Nim) uses `ctrie.put(key, val): Option[V]` and `ctrie.remove(key): Option[V]` (and `skiplist` equivalents) to receive the displaced `Option[pointer]` and immediately pass any displaced `PyObject*` to `phyne`'s deferred `Py_DecRef` queue, and manages a companion atomic slot table in `lockless.BroadcastRing` so overwritten `PyRefBox` entries on `omDropOldest` and remaining entries on `destroy` are deterministically decref'd.

---

### `[MED-01]` Free-Threaded Python (`3.13t`–`3.15t`) `Py_LIMITED_API` Header Conflict & Exported `Py_IncRef`/`Py_DecRef` Requirement
- **Severity**: `MED` (Compilation failure if `#define Py_LIMITED_API` is combined with `<Python.h>` on 3.13t/3.14t; ABI crash if inline `Py_INCREF` struct offsets are used across GIL vs. Free-Threaded builds)
- **Locations in Audited Docs**:
  - `design.md:298-307`, `design.md:320-327`, `design.md:483`
- **Analysis**:
  - In CPython `3.13t` and `3.14t` (`Py_GIL_DISABLED`), CPython's `<Python.h>` emits `#error "Py_LIMITED_API is incompatible with Py_GIL_DISABLED"`, and the C macro `Py_INCREF` manipulates `ob_tid`, `ob_ref_local`, and `ob_ref_shared` at offsets incompatible with GIL-enabled `PyObject`.
  - However, CPython exports the **function symbols** `Py_IncRef(PyObject*)` and `Py_DecRef(PyObject*)` in both GIL and Free-Threaded `libpython`!
- **Remediation Applied to `design.md`**:
  - `phyne/abi3.nim` declares CPython ABI functions directly in Nim via `{.importc, cdecl.}` (without `#include <Python.h>`) and exclusively calls the exported function symbols `Py_IncRef` and `Py_DecRef` (never inline `ob_refcnt` struct manipulation), enabling clean compilation and binary execution across both CPython 3.12–3.15 (`abi3`) and Free-Threaded 3.13t–3.15t (`abi3t` with `Py_mod_gil = Py_MOD_GIL_NOT_USED`).

---

### `[MED-02]` Exact Line-Number Citations Corrected in `understanding.md`
- **Severity**: `MED` (Stage 1 Fact-Check Gate line-citation precision)
- **Empirical Line Corrections Applied to `understanding.md`**:
  1. `bqueue128.nim`: `BQueue128Slot[T]` is at line `50` (was cited as `36`); `compareExchangeWeak(cell[], expected, desired)` is at lines `138-139` (was cited as `compareExchangeStrong` at `141`).
  2. `queue.nim`: `itemCount: Atomic[int]` is at lines `392` and `404` (was cited as `402`).
  3. `streambuffer.nim`: `StreamRing` is at lines `276-291` (was cited as `261-283`); `MPMCStreamRing` is at lines `545-552` (was cited as `448-459`).
  4. `headerkit/_cli.py`: `--exclude` is at lines `226-232` (no `-e` flag); `-o`/`--output` (`lines 218-225`) uses `dest="output_specs"` (was cited as `dest="outputs"`); `_parse_output_specs()` is at lines `426-470` (was cited as `420-482`).
  5. `headerkit/ir.py`: `Function.calling_convention` is at line `740` (was cited as `715`), and `Function` (`lines 695-772`) has no `doc` field yet.
  6. `headerkit/backends/treesitter.py`: `parser.parse(code.encode("utf-8"))` is at line `512` (was cited as `self._c_parser.parse` at `489`).
  7. `lockfree/include/lockfree.h`: `lf_entry_destructor_fn` is at line `205` (was cited as `49`).

---

### `[LOW-01]` Lock Name Alignment Between `implementation_plan.md` and `design.md`
- **Severity**: `LOW`
- **Locations**: `design.md:491` vs. `implementation_plan.md:15`
- **Remediation Applied**: Aligned the Phase 1 lock name in `design.md:491` to `repo:headerkit:writers-init` to match `implementation_plan.md:15`.

---

## 3. Final Ratification Verdict

With all 8 findings (`CRIT-01`, `CRIT-02`, `HIGH-01`, `HIGH-02`, `HIGH-03`, `MED-01`, `MED-02`, `LOW-01`) documented above and remediated directly in `/Users/eek/Development/pyon/understanding.md` and `/Users/eek/Development/pyon/design.md`, **0 open `CRIT` or `BLOCKER` defects remain**.

**Stage 1 Fact-Check Gate & Stage 3 Adversarial Design Audit: RATIFIED (`@pyon-auditor`).**
