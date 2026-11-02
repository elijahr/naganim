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
    NaganimCffiWriter,
    NaganimFunctionSpec,
    NaganimModuleIr,
    NaganimParamSpec,
    NaganimPyiWriter,
    NaganimWriterPlugin,
)

__version__ = "0.1.0"

__all__ = [
    "AsyncChannel",
    "NaganimAsyncBridge",
    "NaganimBufferOwner",
    "NaganimCffiModule",
    "NaganimCffiWriter",
    "NaganimFunctionSpec",
    "NaganimModuleIr",
    "NaganimParamSpec",
    "NaganimPyiWriter",
    "NaganimRuntimeError",
    "NaganimWriterPlugin",
    "__version__",
    "load_abi3_extension",
    "load_cffi_library",
]
