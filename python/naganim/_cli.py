"""CLI entrypoint (`naganim`) for building Nim extensions and generating `.pyi` stubs and CFFI `cdef` declarations via `headerkit`."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

from ._cffi_loader import load_cffi_library
from .writer_plugin import NaganimWriterPlugin


def _shared_lib_suffix() -> str:
    if sys.platform == "darwin":
        return ".dylib"
    if sys.platform == "win32":
        return ".dll"
    return ".so"


def _run_build(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="naganim build",
        description="Compile a Nim source file with --header:<name>.h, parse with headerkit + NimCleanupTransform + NimJsonDocEnricher, and emit .pyi and .cdef files.",
    )
    parser.add_argument(
        "nim_source",
        help="Path to the .nim extension source file to compile",
    )
    parser.add_argument(
        "--out-dir",
        help="Output directory for compiled library, header, .pyi, and .cdef files",
        default=None,
    )
    parser.add_argument(
        "--out-lib",
        help="Explicit output path for the compiled shared library",
        default=None,
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
    parser.add_argument(
        "--header",
        help="Header filename to pass to nim c --header:<name>.h",
        default=None,
    )
    parser.add_argument(
        "--nim-path",
        action="append",
        default=[],
        help="Additional --path:<dir> arguments passed to nim c",
    )
    args = parser.parse_args(argv)
    nim_src = Path(args.nim_source).resolve()
    if not nim_src.exists():
        raise FileNotFoundError(f"Nim source file not found: {nim_src}")

    out_dir = Path(args.out_dir).resolve() if args.out_dir else nim_src.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    stem = nim_src.stem
    header_name = args.header or f"{stem}.h"
    out_lib = (
        Path(args.out_lib).resolve()
        if args.out_lib
        else out_dir / f"lib{stem}{_shared_lib_suffix()}"
    )
    out_pyi = Path(args.out_pyi).resolve() if args.out_pyi else out_dir / f"{stem}.pyi"
    out_cdef = Path(args.out_cdef).resolve() if args.out_cdef else out_dir / f"{stem}.cdef"

    with tempfile.TemporaryDirectory(prefix=f"naganim_build_{stem}_") as tmp_dir:
        nimcache_dir = Path(tmp_dir)
        cmd = [
            "nim",
            "c",
            "--app:lib",
            "--mm:orc",
            "--threads:on",
            "-d:naganimExtensionModule",
            f"--nimcache:{nimcache_dir}",
            f"--header:{header_name}",
        ]
        for p in args.nim_path:
            cmd.append(f"--path:{p}")
        cmd.extend([f"-o:{out_lib}", str(nim_src)])

        subprocess.run(cmd, check=True)

        header_path = nimcache_dir / header_name
        c_header_arg: Path | None = header_path if header_path.exists() else None

        mod = load_cffi_library(
            out_lib,
            c_header_path=c_header_arg,
            nim_source_path=nim_src,
        )
        plugin = mod.plugin
        out_pyi.write_text(plugin.generate_pyi_stub(), encoding="utf-8")
        out_cdef.write_text(plugin.generate_cffi_cdef(), encoding="utf-8")
    return 0


def main(argv: list[str] | None = None) -> int:
    effective_argv = list(sys.argv[1:] if argv is None else argv)
    if effective_argv and effective_argv[0] == "build":
        return _run_build(effective_argv[1:])

    parser = argparse.ArgumentParser(
        prog="naganim",
        description="Generate PEP 484 .pyi stubs and CFFI cdef declarations from a naganim IR file or compiled shared library (or run `naganim build <source.nim>`).",
    )
    parser.add_argument(
        "source",
        help="Path to a .naganim.ir.json file or a compiled naganim shared library (.so/.dylib/.dll)",
    )
    parser.add_argument(
        "--header",
        help="Optional path to a Nim-generated C header (--header:<name>.h) to parse via headerkit",
        default=None,
    )
    parser.add_argument(
        "--nim-source",
        help="Optional path to the Nim source file for NimJsonDocEnricher enrichment",
        default=None,
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
    args = parser.parse_args(effective_argv)
    src = Path(args.source)
    if not src.exists():
        raise FileNotFoundError(f"Source file not found: {src}")

    if src.suffix == ".json":
        plugin = NaganimWriterPlugin.from_ir_file(
            src,
            c_header_path=args.header,
            nim_source_path=args.nim_source,
        )
    else:
        mod = load_cffi_library(
            src,
            c_header_path=args.header,
            nim_source_path=args.nim_source,
        )
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
