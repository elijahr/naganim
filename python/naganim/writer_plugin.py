"""NaganimWriterPlugin: Dual-target Python stub (.pyi), CFFI cdef, and abi3 loader generator.

Consumes the `.naganim.ir.json` intermediate representation emitted by `naganim`'s
`{.exportpy.}` macro (or `naganim_module_ir_json()`).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class NaganimParamSpec:
    name: str
    nim_type: str
    c_type: str
    py_type: str


@dataclass(frozen=True)
class NaganimFunctionSpec:
    name: str
    c_symbol: str
    py_symbol: str
    doc: str
    has_c_abi: bool
    return_nim_type: str
    return_c_type: str
    return_py_type: str
    params: list[NaganimParamSpec] = field(default_factory=list)


@dataclass(frozen=True)
class NaganimModuleIr:
    module: str
    functions: list[NaganimFunctionSpec] = field(default_factory=list)

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> NaganimModuleIr:
        funcs: list[NaganimFunctionSpec] = []
        for fn in raw.get("functions", []):
            params = [
                NaganimParamSpec(
                    name=str(p["name"]),
                    nim_type=str(p["nim_type"]),
                    c_type=str(p["c_type"]),
                    py_type=str(p["py_type"]),
                )
                for p in fn.get("params", [])
            ]
            funcs.append(
                NaganimFunctionSpec(
                    name=str(fn["name"]),
                    c_symbol=str(fn["c_symbol"]),
                    py_symbol=str(fn["py_symbol"]),
                    doc=str(fn.get("doc", "")),
                    has_c_abi=bool(fn.get("has_c_abi", False)),
                    return_nim_type=str(fn["return_nim_type"]),
                    return_c_type=str(fn["return_c_type"]),
                    return_py_type=str(fn["return_py_type"]),
                    params=params,
                )
            )
        return cls(module=str(raw["module"]), functions=funcs)

    @classmethod
    def from_json(cls, json_str: str) -> NaganimModuleIr:
        return cls.from_dict(json.loads(json_str))


class NaganimWriterPlugin:
    """Generates `.pyi` type stubs, CFFI `cdef` declarations, and loader modules."""

    BASE_CFFI_CDEF = """
typedef struct {
    void* data;
    size_t len;
    size_t itemsize;
    int readonly;
    int ndim;
    const char* format;
    void* owner_ctx;
    void (*release_fn)(void*);
} naganim_buf_view_t;

int naganim_init_runtime(void);
int naganim_shutdown_runtime(void);
void naganim_clear_error(void);
const char* naganim_last_error(void);
void naganim_set_last_error(const char* msg);
int naganim_flush_deferred_decrefs(void);
int naganim_deferred_decref_count(void);
void naganim_buf_release(naganim_buf_view_t* view);
const char* naganim_module_ir_json(void);

void* naganim_async_bridge_create(int num_workers);
void naganim_async_bridge_destroy(void* bridge_ptr);
int naganim_async_bridge_read_fd(void* bridge_ptr);
int naganim_async_drain_wakeup(void* bridge_ptr);
int naganim_async_pop_completion(
    void* bridge_ptr,
    uint64_t* out_future_id,
    int* out_status,
    int64_t* out_int,
    double* out_float,
    const char** out_str
);
int naganim_async_submit_compute(
    void* bridge_ptr,
    uint64_t future_id,
    int op_code,
    int64_t arg_a,
    int64_t arg_b
);
int naganim_async_channel_push_int(void* bridge_ptr, uint64_t channel_id, int64_t val);
int naganim_async_channel_close(void* bridge_ptr, uint64_t channel_id);
""".strip()

    def __init__(self, ir: NaganimModuleIr) -> None:
        self.ir = ir

    @classmethod
    def from_ir_file(cls, path: str | Path) -> NaganimWriterPlugin:
        text = Path(path).read_text(encoding="utf-8")
        return cls(NaganimModuleIr.from_json(text))

    @classmethod
    def from_ir_json(cls, json_str: str) -> NaganimWriterPlugin:
        return cls(NaganimModuleIr.from_json(json_str))

    def generate_pyi_stub(self) -> str:
        lines: list[str] = [
            f"# Auto-generated PEP 484 stub for naganim module `{self.ir.module}`",
            "from __future__ import annotations",
            "from typing import Any",
            "",
        ]
        for fn in self.ir.functions:
            param_sig = ", ".join(f"{p.name}: {p.py_type}" for p in fn.params)
            lines.append(f"def {fn.name}({param_sig}) -> {fn.return_py_type}:")
            if fn.doc:
                lines.append(f'    """{fn.doc}"""')
            lines.append("    ...")
            lines.append("")
        return "\n".join(lines)

    def generate_cffi_cdef(self) -> str:
        lines: list[str] = [self.BASE_CFFI_CDEF, ""]
        for fn in self.ir.functions:
            if not fn.has_c_abi:
                continue
            c_params: list[str] = [f"{p.c_type} {p.name}" for p in fn.params]
            if fn.return_nim_type != "void" and fn.return_c_type != "void":
                c_params.append(f"{fn.return_c_type}* out_res")
            param_list = ", ".join(c_params) if c_params else "void"
            lines.append(f"int {fn.c_symbol}({param_list});")
        return "\n".join(lines)
