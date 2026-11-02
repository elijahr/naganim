"""Comprehensive Python & Asyncio Integration Test Suite for `naganim`.

Compiles `tests/python/nim_test_ext.nim` into a real native shared library and
verifies:
1. CFFI ABI mode (`load_cffi_library`)
2. CPython PEP 489 / PEP 384 `abi3` & PEP 803 `abi3t` extension mode (`load_abi3_extension`)
3. Two-tier zero-copy Buffer Protocol (`PinnedBuffer` & `ScopedSeqBuffer` negative controls)
4. Multi-threaded `PyObj` destruction on Nim `TaskPool` worker threads via the
   wait-free deferred `Py_DecRef` queue (`BQueue128` + `TreiberStack`)
5. Lock-free `NaganimAsyncBridge` & `AsyncChannel` (`async for`) over `asyncio`
6. `NaganimWriterPlugin` and `naganim-gen` CLI `.pyi` stub & CFFI `cdef` generation
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest
from naganim._cli import main as naganim_cli_main

from naganim import (
    NaganimAsyncBridge,
    NaganimCffiModule,
    NaganimRuntimeError,
    load_abi3_extension,
    load_cffi_library,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
EXT_NIM_SRC = Path(__file__).resolve().parent / "nim_test_ext.nim"


@pytest.fixture(scope="session")
def compiled_ext_path(tmp_path_factory: pytest.TempPathFactory) -> Path:
    build_dir = tmp_path_factory.mktemp("naganim_ext_build")
    suffix = ".dylib" if sys.platform == "darwin" else (".dll" if sys.platform == "win32" else ".so")
    out_lib = build_dir / f"libnim_test_ext{suffix}"
    cmd = [
        "nim",
        "c",
        "--app:lib",
        "--mm:orc",
        "--threads:on",
        "-d:naganimExtensionModule",
        f"--out:{out_lib}",
        str(EXT_NIM_SRC),
    ]
    proc = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True, check=False)
    assert proc.returncode == 0, f"Nim extension compilation failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
    assert out_lib.exists()
    return out_lib


@pytest.fixture(scope="session")
def cffi_ext(compiled_ext_path: Path) -> NaganimCffiModule:
    return load_cffi_library(compiled_ext_path)


@pytest.fixture(scope="session")
def abi3_ext(compiled_ext_path: Path) -> ModuleType:
    return load_abi3_extension("nim_test_ext", compiled_ext_path)


# ---------------------------------------------------------------------------
# 1. CFFI ABI Mode Tests & Negative Controls
# ---------------------------------------------------------------------------
def test_cffi_primitives_and_strings(cffi_ext: NaganimCffiModule) -> None:
    assert cffi_ext.add_ints(120, -45) == 75
    assert cffi_ext.scale_float(2.5, 4.0) == 10.0
    assert cffi_ext.scale_cint_float(3.5, 4) == 14.0
    assert cffi_ext.bitmask_u64(3, 4, 5) == 53
    assert cffi_ext.greet("nim") == "Hello from Nim, nim!"
    assert cffi_ext.negate_bool(True) is False
    assert cffi_ext.negate_bool(False) is True


def test_cffi_borrow_guard_and_deferred_decref_controls(cffi_ext: NaganimCffiModule) -> None:
    cffi_ext.flush_deferred_decrefs()
    assert cffi_ext.deferred_decref_count() == 0
    assert cffi_ext.active_borrowers() == 0

    assert cffi_ext.enter_borrow() == 1
    assert cffi_ext.active_borrowers() == 1
    assert cffi_ext.exit_borrow() == 0
    assert cffi_ext.active_borrowers() == 0


def test_cffi_zero_copy_pinned_buffer(cffi_ext: NaganimCffiModule) -> None:
    with cffi_ext.make_pinned_bytes(5) as buf_owner:
        assert buf_owner.byte_length == 5
        assert buf_owner.readonly is False
        assert cffi_ext.last_pinned_export_count() == 1
        mv = memoryview(buf_owner.to_buffer())
        assert list(mv) == [1, 2, 3, 4, 5]
        # Mutate in-place through Python memoryview and verify Nim sees the mutation without copy!
        mv[0] = 100
        mv[4] = 50
        assert cffi_ext.sum_pinned_last() == 100 + 2 + 3 + 4 + 50
        del mv
    assert cffi_ext.last_pinned_export_count() == 0


def test_cffi_negative_controls(cffi_ext: NaganimCffiModule) -> None:
    with pytest.raises(TypeError, match="takes exactly 2 argument"):
        cffi_ext.add_ints(1)

    with pytest.raises(TypeError, match="must be int"):
        cffi_ext.add_ints("bad", 2)

    with pytest.raises(TypeError, match="must be int"):
        cffi_ext.add_ints(True, 2)

    with pytest.raises(TypeError, match="must be str"):
        cffi_ext.greet(12345)

    with pytest.raises(NaganimRuntimeError, match="ValueError: cffi negative control"):
        cffi_ext.fail_with_value_error("cffi negative control")

    with pytest.raises(NaganimRuntimeError, match="IndexDefect: deliberate bounds defect"):
        cffi_ext.fail_with_defect()


# ---------------------------------------------------------------------------
# 2. CPython PEP 489 / PEP 384 `abi3` & `abi3t` Extension Mode Tests
# ---------------------------------------------------------------------------
def test_abi3_primitives_and_containers(abi3_ext: ModuleType) -> None:
    assert abi3_ext.add_ints(1000, 234) == 1234
    assert abi3_ext.scale_float(1.5, 3.0) == 4.5
    assert abi3_ext.scale_cint_float(2.25, 4) == 9.0
    assert abi3_ext.bitmask_u64(7, 3, 2) == 58
    assert abi3_ext.greet("python") == "Hello from Nim, python!"
    assert abi3_ext.negate_bool(True) is False
    assert abi3_ext.reverse_seq([10, 20, 30, 40]) == [40, 30, 20, 10]
    assert abi3_ext.lookup_or_none(True, 777) == 777
    assert abi3_ext.lookup_or_none(False, 777) is None
    assert abi3_ext.merge_counts({"a": 1, "b": 5}, 10) == {"a": 11, "b": 15}
    assert abi3_ext.swap_pair((99, "ninety-nine")) == ("ninety-nine", 99)


def test_abi3_zero_copy_pep3118_memoryview_and_resize_guard(abi3_ext: ModuleType) -> None:
    mv = abi3_ext.make_pinned_bytes(4)
    assert isinstance(mv, memoryview)
    assert mv.readonly is False
    assert abi3_ext.last_pinned_export_count() == 1
    assert mv.tobytes() == bytes([1, 2, 3, 4])

    # Mutate byte 1 in Python and verify Nim immediately sees it via zero-copy shared memory
    mv[1] = 200
    assert abi3_ext.sum_pinned_last() == 1 + 200 + 3 + 4

    mv.release()
    assert abi3_ext.last_pinned_export_count() == 0

    # Readonly PinnedBuffer negative control: writing through memoryview raises TypeError
    ro_mv = abi3_ext.make_readonly_pinned_bytes(3)
    assert isinstance(ro_mv, memoryview)
    assert ro_mv.readonly is True
    assert abi3_ext.last_pinned_export_count() == 1
    assert ro_mv.tobytes() == bytes([10, 11, 12])
    with pytest.raises(TypeError):
        ro_mv[0] = 99
    ro_mv.release()
    assert abi3_ext.last_pinned_export_count() == 0

    # Verify 1,000 buffer exports and releases leave exportCount at 0 without leaking
    for _ in range(1000):
        tmp_mv = abi3_ext.make_pinned_bytes(2)
        tmp_mv.release()
    assert abi3_ext.last_pinned_export_count() == 0

    # Negative control: ScopedSeqBuffer resize while exported raises BufferError in Python
    with pytest.raises(BufferError, match="Cannot resize or reallocate ScopedSeqBuffer"):
        abi3_ext.trigger_scoped_resize_defect()


def test_abi3_wait_free_deferred_decref_from_nim_taskpool(abi3_ext: ModuleType) -> None:
    payload = ["untracked-heap-list", 1, 2, 3]
    abi3_ext.flush_pending_decrefs()
    rc_before = sys.getrefcount(payload)

    # Spawn 24 Nim TaskPool tasks that each receive a stolen PyObj reference to `payload`
    # and destroy it on a non-Python worker thread without the GIL.
    # `spawn_threaded_pyobj_drop` returns the exact pending count (24) recorded immediately
    # after the worker threads finish, and then the abi3 return boundary (`toPyRaw` / `=destroy`)
    # automatically drains all 24 deferred DecRefs on the Python thread!
    pending = abi3_ext.spawn_threaded_pyobj_drop(payload, 24)
    assert pending == 24
    assert sys.getrefcount(payload) == rc_before
    assert abi3_ext.flush_pending_decrefs() == 0


def test_abi3_negative_controls(abi3_ext: ModuleType) -> None:
    with pytest.raises(TypeError, match="takes exactly 2 argument"):
        abi3_ext.add_ints(42)

    with pytest.raises(TypeError, match="Expected Python int, got bool"):
        abi3_ext.add_ints(True, 1)

    with pytest.raises(RuntimeError, match="ValueError: abi3 boom"):
        abi3_ext.fail_with_value_error("abi3 boom")

    with pytest.raises(RuntimeError, match="IndexDefect: deliberate bounds defect"):
        abi3_ext.fail_with_defect()


# ---------------------------------------------------------------------------
# 3. Lock-Free `naganim.asyncio` Event-Loop Bridge & `AsyncChannel` Tests
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_asyncio_bridge_taskpool_offloading_and_channel(cffi_ext: NaganimCffiModule) -> None:
    async with (
        NaganimAsyncBridge(cffi_ext, num_workers=4) as bridge,
        NaganimAsyncBridge(cffi_ext, num_workers=2) as second_bridge,
    ):
        # Single TaskPool op=1 (registered extComputeSumSquares(1, 100) = 338350)
        res = await bridge.submit_compute(1, 1, 100)
        assert res == 338350

        # Concurrent gather across 12 parallel TaskPool jobs across BOTH bridges
        tasks = [bridge.submit_compute(1, 1, n) for n in range(1, 13)]
        second_tasks = [second_bridge.submit_compute(1, 1, n) for n in range(1, 7)]
        results = await asyncio.gather(*tasks)
        second_results = await asyncio.gather(*second_tasks)
        expected = [sum(i * i for i in range(1, n + 1)) for n in range(1, 13)]
        assert results == expected
        assert second_results == expected[:6]

        # Register custom compute op from Python and execute on TaskPool workers
        bridge.register_op(10, lambda a, b: a * b + 7)
        try:
            custom_res = await bridge.submit_compute(10, 6, 9)
            assert custom_res == 61
        finally:
            bridge.unregister_op(10)

        # Register op 11 on second_bridge without manual unregister; closing second_bridge must unregister it
        second_bridge.register_op(11, lambda a, b: a - b)
        assert await second_bridge.submit_compute(11, 20, 5) == 15
        second_bridge.close()
        with pytest.raises(NaganimRuntimeError, match="Unregistered async task opcode: 11"):
            await bridge.submit_compute(11, 20, 5)

        # Negative control: task raising error on worker thread rejects the asyncio.Future
        with pytest.raises(NaganimRuntimeError, match="deliberate worker failure"):
            await bridge.submit_compute(2, 0, 0)

        # AsyncChannel (`async for`) streaming values via lock-free ring + pipe wakeup
        ch = bridge.create_channel()

        async def _producer() -> None:
            for item in [11, 22, 33, 44]:
                await asyncio.sleep(0.002)
                ch.push_from_nim(item)
            await asyncio.sleep(0.002)
            ch.close_from_nim()

        prod_task = asyncio.create_task(_producer())
        collected: list[int] = []
        async for val in ch:
            collected.append(val)
        await prod_task
        assert collected == [11, 22, 33, 44]


# ---------------------------------------------------------------------------
# 4. `NaganimWriterPlugin` & `naganim` CLI + `headerkit` Integration Tests
# ---------------------------------------------------------------------------
def test_writer_plugin_and_cli(compiled_ext_path: Path, tmp_path: Path) -> None:
    from headerkit.ir import Header
    from headerkit.writers import get_writer

    pyi_out = tmp_path / "nim_test_ext.pyi"
    cdef_out = tmp_path / "nim_test_ext.h"
    rc = naganim_cli_main(
        [
            str(compiled_ext_path),
            "--out-pyi",
            str(pyi_out),
            "--out-cdef",
            str(cdef_out),
        ]
    )
    assert rc == 0
    pyi_text = pyi_out.read_text(encoding="utf-8")
    cdef_text = cdef_out.read_text(encoding="utf-8")

    # Verify registered headerkit writers and Header IR pipeline
    pyi_writer_cls = get_writer("naganim-pyi")
    cffi_writer_cls = get_writer("naganim-cffi")
    assert pyi_writer_cls is not None
    assert cffi_writer_cls is not None

    mod = load_cffi_library(compiled_ext_path, nim_source_path=EXT_NIM_SRC)
    pyi_header = mod.plugin.to_pyi_header()
    cffi_header = mod.plugin.to_cffi_header()
    assert isinstance(pyi_header, Header)
    assert isinstance(cffi_header, Header)

    expected_lines = [
        "# Auto-generated by headerkit - do not edit",
        "from __future__ import annotations",
        "",
        "from typing import Any",
        "",
        "def add_ints(a: int, b: int) -> int:",
        '    """Adds two 64-bit integers and returns their sum."""',
        "    ...",
        "",
        "def scale_float(x: float, factor: float) -> float:",
        '    """Multiplies two 64-bit floats."""',
        "    ...",
        "",
        "def greet(name: str) -> str:",
        '    """Formats a greeting string."""',
        "    ...",
        "",
        "def negate_bool(flag: bool) -> bool:",
        '    """Negates a boolean value."""',
        "    ...",
        "",
        "def reverse_seq(items: list[int]) -> list[int]:",
        '    """Reverses a sequence of 64-bit integers."""',
        "    ...",
        "",
        "def lookup_or_none(present: bool, val: int) -> int | None:",
        '    """Returns `some(val)` when `present` is true, or `none(int64)` otherwise."""',
        "    ...",
        "",
        "def merge_counts(tbl: dict[str, int], bonus: int) -> dict[str, int]:",
        '    """Adds `bonus` to every entry in `tbl`."""',
        "    ...",
        "",
        "def swap_pair(pair: Any) -> Any:",
        '    """Swaps a 2-tuple of `(int64, string)` into `(string, int64)`."""',
        "    ...",
        "",
        "def make_pinned_bytes(n: int) -> memoryview:",
        '    """Allocates a zero-copy `PinnedBuffer[byte]` of length `n` initialized to `1..n`."""',
        "    ...",
        "",
        "def sum_pinned_last() -> int:",
        '    """Sums the bytes of `gLastPinnedBuf`, proving zero-copy in-place mutations from Python."""',
        "    ...",
        "",
        "def last_pinned_export_count() -> int:",
        '    """Returns the current active exportCount on `gLastPinnedBuf`."""',
        "    ...",
        "",
        "def trigger_scoped_resize_defect() -> int:",
        '    """Negative control: exports a ScopedSeqBuffer and attempts to resize it while exported."""',
        "    ...",
        "",
        "def fail_with_value_error(msg: str) -> int:",
        '    """Negative control: raises a Nim ValueError across the language boundary."""',
        "    ...",
        "",
        "def fail_with_defect() -> int:",
        '    """Negative control: raises a Nim IndexDefect across the language boundary."""',
        "    ...",
        "",
        "def spawn_threaded_pyobj_drop(obj: Any, copies: int) -> int:",
        '    """Clones `obj` `copies` times, transfers ownership to non-Python `TaskPool`\n    worker threads, waits for worker destruction (which enqueues all `copies`\n    into `gDeferredDecRefQueue`), and returns `deferredDecRefPendingCount()`\n    BEFORE flushing so Python can verify deferred queueing and subsequent flush.\n    """',
        "    ...",
        "",
        "def flush_pending_decrefs() -> int:",
        '    """Explicitly flushes `gDeferredDecRefQueue` on the Python thread and returns\n    the number of decremented `PyObject*` references.\n    """',
        "    ...",
        "",
        "def make_readonly_pinned_bytes(n: int) -> memoryview:",
        '    """Allocates a read-only zero-copy `PinnedBuffer[byte]` of length `n`."""',
        "    ...",
        "",
        "def scale_cint_float(x: float, factor: int) -> float:",
        '    """Multiplies a Nim `float` by a `cint` factor."""',
        "    ...",
        "",
        "def bitmask_u64(mask: int, shift: int, offset: int) -> int:",
        '    """Shifts `mask` left by `shift` bits and adds `offset`."""',
        "    ...",
        "",
    ]
    expected_pyi = "\n".join(expected_lines)
    assert pyi_text == expected_pyi
    assert "int naganim_c_add_ints(int64_t a, int64_t b, int64_t * out_res);" in cdef_text
    assert "int naganim_c_make_pinned_bytes(int64_t n, naganim_buf_view_t * out_res);" in cdef_text
    assert "int naganim_enter_borrow(void);" in cdef_text
    assert "int naganim_pop_deferred_decref(void ** out_ptr);" in cdef_text


def test_cli_build_end_to_end_with_headerkit(tmp_path: Path) -> None:
    build_out = tmp_path / "cli_build_out"
    rc = naganim_cli_main(
        [
            "build",
            str(EXT_NIM_SRC),
            "--out-dir",
            str(build_out),
            "--nim-path",
            str(REPO_ROOT / "src"),
        ]
    )
    assert rc == 0
    pyi_file = build_out / "nim_test_ext.pyi"
    cdef_file = build_out / "nim_test_ext.cdef"
    assert pyi_file.exists()
    assert cdef_file.exists()
    assert "def add_ints(a: int, b: int) -> int:" in pyi_file.read_text(encoding="utf-8")
    assert "int naganim_c_add_ints(" in cdef_file.read_text(encoding="utf-8")
