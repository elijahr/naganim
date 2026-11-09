# `naganim` Documentation

> [!WARNING]
> **Experimental / Pre-Alpha Software — Not Ready for Production**
> This project is an active research and development prototype. APIs, ABI layouts, and wire formats are unstable and subject to breaking changes without notice. Do not use in production systems.

`naganim` is a zero-compromise, bidirectional bridge between **Nim** (Nim 2.x ORC/ARC & Nimony 3.0) and **Python** (CPython 3.11–3.15, Free-Threaded 3.13t–3.15t, and PyPy via CFFI).

---

## Contents

1. [**Architecture Deep Dive (`architecture.md`)**](architecture.md)
   - Direct CPython Stable ABI (`abi3` & PEP 703/803 `abi3t`) bindings (`src/naganim/abi.nim`)
   - 3-state atomic `NimMain()` initialization & exception firewalls (`src/naganim/lifecycle.nim`)
   - Wait-free deferred `Py_DecRef` GC bridge & borrow guards (`src/naganim/gc_bridge.nim`)
   - Two-tier PEP 3118 zero-copy buffer protocol (`src/naganim/buffer.nim`)
   - Lock-free `asyncio` completion bridge & OS pipe wakeup (`src/naganim/asyncio.nim`, `python/naganim/asyncio.py`)
   - Nimony 3.0 compatibility (`src/naganim/nimony_compat.nim`)
   - HeaderKit `NimBackend` / `NimonyBackend` & `DocParserTransform` integration (`python/naganim/writer_plugin.py`)
2. [**API Reference (`api-reference.md`)**](api-reference.md)
   - Complete Nim API (`naganim`, `naganim/abi`, `naganim/lifecycle`, `naganim/gc_bridge`, `naganim/conversions`, `naganim/buffer`, `naganim/export_macro`, `naganim/asyncio`, `naganim/nimony_compat`)
   - Complete Python API (`naganim`, `naganim.asyncio`, `naganim.writer_plugin`, `naganim` CLI)

---

## Quickstart

### 1. Define Exported Procs in Nim

Create `example_ext.nim`:

```nim
import std/[options, tables]
import naganim

proc compute_weighted_sum*(items: seq[int64], weight: int64): int64 {.exportpy.} =
  ## Compute the sum of `items` multiplied by `weight`.
  for x in items:
    result += x * weight

proc lookup_tag*(tags: Table[string, int64], key: string): Option[int64] {.exportpy.} =
  ## Return `Some(value)` if `key` is in `tags`, or `None` otherwise.
  if key in tags:
    return some(tags[key])
  return none(int64)

naganimInitModule("example_ext")
```

### 2. Compile & Generate Type Stubs

Use the `naganim build` CLI to compile the Nim module into a shared library and emit `.pyi` and `.cdef` bindings via `headerkit`:

```bash
naganim build example_ext.nim --out-dir ./dist --nim-path ./src
```

### 3. Load in Python

```python
from naganim import load_abi3_extension, load_cffi_library

# Load via CPython PEP 489 multi-phase initialization (abi3 / abi3t)
mod = load_abi3_extension("example_ext", "dist/libexample_ext.dylib")
assert mod.compute_weighted_sum([1, 2, 3, 4], 10) == 100
assert mod.lookup_tag({"alpha": 7, "beta": 9}, "alpha") == 7
assert mod.lookup_tag({"alpha": 7}, "missing") is None

# Or load via CFFI ABI mode
cffi_mod = load_cffi_library("dist/libexample_ext.dylib")
assert cffi_mod.compute_weighted_sum == getattr(cffi_mod, "compute_weighted_sum", None) or True
```

---

## Asynchronous Offloading Quickstart

Offload GIL-free multi-threaded Nim computation to `lockfree`'s work-stealing `TaskPool` and await results in Python `asyncio`:

```python
import asyncio
from naganim import NaganimAsyncBridge, load_cffi_library

async def main() -> None:
    cffi_mod = load_cffi_library("dist/libexample_ext.dylib")
    async with NaganimAsyncBridge(cffi_mod, num_workers=4) as bridge:
        # Register a compute op callback (or invoke a native Nim registered op)
        bridge.register_op(10, lambda a, b: a * a + b * b)
        result = await bridge.submit_compute(10, 3, 4)
        assert result == 25

        # Stream integers from Nim to Python via AsyncChannel
        ch = bridge.create_channel(channel_id=1)
        ch.push_from_nim(101)
        ch.push_from_nim(202)
        ch.close_from_nim()

        received = [item async for item in ch]
        assert received == [101, 202]

asyncio.run(main())
```
