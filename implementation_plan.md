# Implementation Plan: `naganim` & `lockless` Ecosystem

> **CRITICAL BRANCH & PR ISOLATION INVARIANT**
> Zero direct commits or pushes to `main` or `master` are permitted in `/Users/eek/Development/headerkit`, `/Users/eek/Development/lockfree`, `axiomantic/polyform`, or any existing repository. Every task MUST execute inside an isolated Vine strand (`vine new <task_id> --branch feat/<name>`), pass Keys 1 & 2 (`vine submit`), pass independent Key 3 Adversarial Audit (`vine audit approve --auditor agy-worker-4`), and be pushed as a feature branch for a Pull Request (`gh pr create`) rather than weaving directly into `main`.

## 1. Swarm Roster & Role Mapping
| Worker Name | Persona | Role | Assigned Subsystems |
| :--- | :--- | :--- | :--- |
| `pyon-architect` | Spring-Compass | Staff Systems Architect | Dialectical Stage 1/2 (`understanding.md`, `design.md`), Phase 2 (`lockfree` zero-copy C ABI & 0-to-1 wakeup flags), Phase 3 (`naganim` core architecture) |
| `pyon-auditor` | Briar-Lens | Verification & Adversarial Auditor | Dialectical Stage 1 Fact-Check Gate, Stage 3 (`audit_report.md`), and Key 3 Pre-PR Five-Pillar Code Audit (`vine audit approve`) across all strands |
| `pyon-implementer` | Sorrel-Darter | DevEx & Implementation Lead | Phase 1 (`headerkit` Nim `--header` macros, `NimCleanupTransform`, `PyiWriter`), Phase 3/4 Python packaging & `lockless` wrappers |

---

## 2. Distributed Locking & Concurrency Schedule
- **Lock Target**: `repo:headerkit:writers-init`
  - *Owner*: `pyon-implementer`
  - *Command*: `rhizo lock repo:headerkit:writers-init 900 --fencing`
- **Lock Target**: `repo:lockfree:cabi-headers`
  - *Owner*: `pyon-architect`
  - *Command*: `rhizo lock repo:lockfree:cabi-headers 900 --fencing`

---

## 3. Vine Strand & Pull Request Lifecycle Matrix
1. **Provision Isolated Strand (in target repo)**:
   ```bash
   vine new <task_id> --branch feat/<task_id>
   ```
2. **Execute Work Inside Strand**:
   - Implement Provider + live Consumer call-sites (Two-Point Diff).
   - Update `CHANGELOG.md` via `vine changelog "..."`.
   - Run full linter and test suite (`ruff`, `mypy --strict`, `pytest`, or `nimble test` / `nimble cabi`).
3. **Three-Key Gate Verification**:
   - **Worker**: Runs `vine submit --author <worker>` (Keys 1 & 2).
   - **Independent Auditor (`pyon-auditor`)**: Runs Five-Pillar Presumption-of-Guilt audit and executes `vine audit approve --auditor pyon-auditor` (Key 3).
4. **Pull Request Creation (Never Push to `main`)**:
   - Push the ratified feature branch (`feat/<task_id>`) to `origin` and open a Pull Request (`gh pr create`), leaving `main`/`master` untouched.

---

## 4. Phase-by-Phase Task Checklist

### Phase 0: Grounded Dialectical Research, Design & Audit (`understanding.md`, `design.md`, `audit_report.md`)
- [x] **Task 0.1: Grounded Research & Architecture Specification** (`pyon-architect`)
  - *Target*: `/Users/eek/Development/pyon/understanding.md` and `/Users/eek/Development/pyon/design.md`
  - *Scope*: Inspect exact line numbers and signatures across `/Users/eek/Development/headerkit` (`ir.py`, `_cli.py`, `backends/libclang.py`, `backends/treesitter.py`, `transforms/`, `writers/`) and `/Users/eek/Development/lockfree` (`include/lockfree.h`, `include/lockfree_streambuffer.h`, `include/lockfree_bqueue128.h`, `src/lockfree/cabi.nim`) and document exact interfaces for `headerkit`, `lockfree`, `naganim`, and `lockless`.
- [x] **Task 0.2: Fact-Check Gate & Adversarial Design Audit** (`pyon-auditor`)
  - *Dependency*: Task 0.1
  - *Target*: `/Users/eek/Development/pyon/audit_report.md`
  - *Verification*: Verify every cited file path and line number in `understanding.md` and stress-test `design.md` until 0 `CRIT` or `BLOCKER` defects remain.

### Phase 1: `axiomantic/headerkit` Nim Dialect & `.pyi` Stub Writer (PR to `headerkit`)
- [x] **Task 1.1: HeaderKit Nim Support, Cleanup Transform & `pyi` Writer** (`pyon-implementer`)
  - *Repo*: `/Users/eek/Development/headerkit`
  - *Strand*: `vine new task-headerkit-nim-pyi --branch feat/nim-header-pyi`
  - *Provider*:
    1. `headerkit/_cli.py`: Add `-b` short flag alias for `--backend`.
    2. `headerkit/backends/treesitter.py` & `headerkit/backends/libclang.py`: Support Nim `nimbase.h` calling-convention/export macros (`N_CDECL`, `N_NOCONV`, `N_STDCALL`, `N_INLINE`, `N_LIB_IMPORT`, `N_LIB_PRIVATE`, `N_LIB_EXPORT`, `NCSTRING`) in `treesitter` and auto-detect `nim dump` `libpath` when `#include "nimbase.h"` is encountered in `libclang`.
    3. `headerkit/transforms/`: Add `NimCleanupTransform` stripping Nim `_p0`, `_p1` parameter suffixes and `` `gensym0 `` hygiene suffixes, and filtering `signalHandler`.
    4. `headerkit/writers/pyi.py`: Implement PEP 484 `.pyi` type stub writer (`PyiWriter`, registered as `"pyi"`).
  - *Consumer / Call-Site*: Wire `PyiWriter` into `headerkit/writers/__init__.py` and CLI `-w pyi`, wire `NimCleanupTransform` into `headerkit/transforms/__init__.py`, and wire `-b` into `_cli.py`.
  - *Verification*: `uv run ruff check . && uv run mypy --strict headerkit && uv run pytest` + `vine submit --author pyon-implementer` + Key 3 audit by `pyon-auditor` + feature branch PR.

### Phase 2: `elijahr/lockfree` Zero-Copy Reserve/Commit & 0-to-1 Wakeup C ABI (PR to `lockfree`)
- [x] **Task 2.1: Lockfree Zero-Copy StreamBuffer & 0-to-1 Empty-Transition C ABI** (`pyon-architect`)
  - *Repo*: `/Users/eek/Development/lockfree`
  - *Strand*: `vine new task-lockfree-cabi --branch feat/zerocopy-stream-wakeup-cabi`
  - *Provider*:
    1. `include/lockfree_streambuffer.h` & Nim C ABI implementation: Add `lf_stream_reserve_write`, `lf_stream_commit_write`, `lf_stream_peek_read`, `lf_stream_consume_read` for two-phase zero-copy buffer access.
    2. `include/lockfree.h` & `include/lockfree_bqueue128.h`: Add `lf_push_ex` / `lf_bqueue128_push_ex` returning `bool* out_was_empty` on atomic 0-to-1 transition for edge-triggered `eventfd`/`kqueue` wakeups.
    3. Verify destructor drain across C ABI collection `destroy` routines so queued `PyObject*` pointers never leak.
  - *Consumer / Call-Site*: Wire into `tests/` C ABI test suite (`nimble cabi`).
  - *Verification*: `nimble test && nimble cabi` + `vine submit --author pyon-architect` + Key 3 audit by `pyon-auditor` + feature branch PR.

### Phase 3: `naganim` Core Bidirectional Nim-Python Bridge (`abi3`/`abi3t` + `cffi` + `naganim/asyncio`)
- [x] **Task 3.1: `naganim` Core Runtime, `PyObj` Deferred DecRef, Buffer Protocol & `naganim/asyncio`** (`pyon-architect` & `pyon-implementer`)
  - *Dependency*: Task 1.1, Task 2.1
  - *Repo*: `/Users/eek/Development/naganim` (or `/Users/eek/Development/pyon` renamed/configured as `naganim`)
  - *Provider*: `src/naganim/abi.nim`, `src/naganim/pyobj.nim`, `src/naganim/buffer.nim`, `src/naganim/export_macro.nim`, `src/naganim/asyncio.nim`, `python/naganim/asyncio.py`, `python/naganim/writer_plugin.py`
  - *Consumer / Call-Site*: End-to-end Nim-to-Python and Python-to-Nim extension modules tested under CPython (`abi3`/`abi3t`) and CFFI.

### Phase 4: `lockless` Flagship Python Package (`pip install lockless`)
- [x] **Task 4.1: `lockless` High-Contention Collections, Zero-Copy DSP Buffers & Async Channels** (`pyon-implementer` & `pyon-architect`)
  - *Dependency*: Task 2.1, Task 3.1
  - *Repo*: `/Users/eek/Development/lockless`
  - *Provider*: `BQueue128`, `SpscQueue`, `MpmcQueue`, `StreamBuffer` (zero-copy `memoryview`), `BroadcastRing`, `ConcurrentDict` (`Ctrie`), `SkipListMap`, `Channel` (`async for`), `TaskPool.map()`.
  - *Consumer / Call-Site*: Live Python test suite + multi-threaded contention benchmark suite.

### Phase 5: `axiomantic/polyform` Polyglot Nim + Free-Threaded Python + Nimony CI Template (PR to `polyform`)
- [x] **Task 5.1: `polyform` Polyglot Nim + Python `abi3t`/`cffi` + `headerkit` + `nimony` CI Workflows** (`pyon-architect`)
  - *Repo*: `/Users/eek/Development/polyform`
  - *Strand*: `vine new task-polyform-ci --branch feat/nim-python-freethreaded-nimony-ci`
  - *Provider & Consumer*: Polyglot `has_nim` + `has_python` template integration with `headerkit` codegen, Free-Threaded Python (`3.13t`, `3.14t`) CI matrix, and `nimony` compatibility verification target, verified by `polyform`'s test suite and submitted via Pull Request (never pushed to `main`).
