"""`phyne` — Next-Generation Bidirectional Nim-Python Interoperability Library."""

from __future__ import annotations

from ._cffi_loader import (
    PhyneBufferOwner,
    PhyneCffiModule,
    PhyneRuntimeError,
    load_abi3_extension,
    load_cffi_library,
)
from .asyncio import AsyncChannel, PhyneAsyncBridge
from .writer_plugin import (
    PhyneFunctionSpec,
    PhyneModuleIr,
    PhyneParamSpec,
    PhyneWriterPlugin,
)

__version__ = "0.1.0"

__all__ = [
    "__version__",
    "AsyncChannel",
    "PhyneAsyncBridge",
    "PhyneBufferOwner",
    "PhyneCffiModule",
    "PhyneFunctionSpec",
    "PhyneModuleIr",
    "PhyneParamSpec",
    "PhyneRuntimeError",
    "PhyneWriterPlugin",
    "load_abi3_extension",
    "load_cffi_library",
]
