## `naganim` — Next-Generation Bidirectional Nim-Python Interoperability Library.
##
## Public Umbrella Module re-exporting:
## - `naganim/nimony_compat`: Nim 2.x & Nimony 3.0 compatibility layer
## - `naganim/abi`: Direct CPython 3.12+ Limited C-ABI (`abi3` & PEP 803 `abi3t`)
## - `naganim/lifecycle`: Runtime initialization, thread-local errors & exception firewalls
## - `naganim/gc_bridge`: `PyObj` ORC lifecycle & wait-free deferred `Py_DecRef` queue
## - `naganim/conversions`: Bidirectional type marshaling (`toPy` / `fromPy`)
## - `naganim/buffer`: Two-tier zero-copy buffer protocol (`PinnedBuffer`, `ScopedSeqBuffer`)
## - `naganim/export_macro`: `{.exportpy.}` / `{.pyexport.}` and `naganimInitModule`
## - `naganim/asyncio`: Lock-free completion ring, OS pipe wakeup & `TaskPool` bridge

import naganim/nimony_compat
import naganim/abi
import naganim/lifecycle
import naganim/gc_bridge
import naganim/conversions
import naganim/buffer
import naganim/export_macro
import naganim/asyncio

export
  nimony_compat,
  abi,
  lifecycle,
  gc_bridge,
  conversions,
  buffer,
  export_macro,
  asyncio
