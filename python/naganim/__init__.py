"""`naganim` — Next-Generation Bidirectional Nim-Python Interoperability Library."""

from __future__ import annotations

from ._cffi_loader import (
    NaganimBufferOwner,
    NaganimCffiModule,
    NaganimRuntimeError,
    load_abi3_extension,
    load_cffi_library,
)
from .asyncio import AsyncChannel, NaganimAsyncBridge
from .writer_plugin import (
    NaganimFunctionSpec,
    NaganimModuleIr,
    NaganimParamSpec,
    NaganimWriterPlugin,
)

__version__ = "0.1.0"

__all__ = [
    "__version__",
    "AsyncChannel",
    "NaganimAsyncBridge",
    "NaganimBufferOwner",
    "NaganimCffiModule",
    "NaganimFunctionSpec",
    "NaganimModuleIr",
    "NaganimParamSpec",
    "NaganimRuntimeError",
    "NaganimWriterPlugin",
    "load_abi3_extension",
    "load_cffi_library",
]
