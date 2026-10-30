"""CLI entrypoint (`naganim-gen`) for generating `.pyi` stubs and CFFI `cdef` declarations."""

from __future__ import annotations

import argparse
from pathlib import Path

from ._cffi_loader import load_cffi_library
from .writer_plugin import NaganimWriterPlugin


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="naganim-gen",
        description="Generate PEP 484 .pyi stubs and CFFI cdef declarations from a naganim IR file or compiled shared library.",
    )
    parser.add_argument(
        "source",
        help="Path to a .naganim.ir.json file or a compiled naganim shared library (.so/.dylib/.dll)",
    )
    parser.add_argument(
        "--out-pyi",
        help="Output path for generated PEP 484 .pyi stub file",
        default=None,
    )
    parser.add_argument(
        "--out-cdef",
        help="Output path for generated CFFI cdef header file",
        default=None,
    )
    args = parser.parse_args(argv)
    src = Path(args.source)
    if not src.exists():
        raise FileNotFoundError(f"Source file not found: {src}")

    if src.suffix == ".json":
        plugin = NaganimWriterPlugin.from_ir_file(src)
    else:
        mod = load_cffi_library(src)
        plugin = mod.plugin

    if args.out_pyi:
        Path(args.out_pyi).write_text(plugin.generate_pyi_stub(), encoding="utf-8")
    if args.out_cdef:
        Path(args.out_cdef).write_text(plugin.generate_cffi_cdef(), encoding="utf-8")
    if not args.out_pyi and not args.out_cdef:
        print(plugin.generate_pyi_stub())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
