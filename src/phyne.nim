## `phyne` — Next-Generation Bidirectional Nim-Python Interoperability Library.
##
## Public Umbrella Module re-exporting:
## - `phyne/nimony_compat`: Nim 2.x & Nimony 3.0 compatibility layer
## - `phyne/abi`: Direct CPython 3.12+ Limited C-ABI (`abi3` & PEP 803 `abi3t`)
## - `phyne/lifecycle`: Runtime initialization, thread-local errors & exception firewalls
## - `phyne/gc_bridge`: `PyObj` ORC lifecycle & wait-free deferred `Py_DecRef` queue
## - `phyne/conversions`: Bidirectional type marshaling (`toPy` / `fromPy`)
## - `phyne/buffer`: Two-tier zero-copy buffer protocol (`PinnedBuffer`, `ScopedSeqBuffer`)
## - `phyne/export_macro`: `{.exportpy.}` / `{.pyexport.}` and `phyneInitModule`
## - `phyne/asyncio`: Lock-free completion ring, OS pipe wakeup & `TaskPool` bridge

import phyne/nimony_compat
import phyne/abi
import phyne/lifecycle
import phyne/gc_bridge
import phyne/conversions
import phyne/buffer
import phyne/export_macro
import phyne/asyncio

export
  nimony_compat,
  abi,
  lifecycle,
  gc_bridge,
  conversions,
  buffer,
  export_macro,
  asyncio
