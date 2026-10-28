"""PhyneWriterPlugin: Dual-target Python stub (.pyi), CFFI cdef, and abi3 loader generator.

Consumes the `.phyne.ir.json` intermediate representation emitted by `phyne`'s
`{.exportpy.}` macro (or `phyne_module_ir_json()`).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class PhyneParamSpec:
    name: str
    nim_type: str
    c_type: str
    py_type: str


@dataclass(frozen=True)
class PhyneFunctionSpec:
    name: str
    c_symbol: str
    py_symbol: str
    doc: str
    has_c_abi: bool
    return_nim_type: str
    return_c_type: str
    return_py_type: str
    params: list[PhyneParamSpec] = field(default_factory=list)


@dataclass(frozen=True)
class PhyneModuleIr:
    module: str
    functions: list[PhyneFunctionSpec] = field(default_factory=list)

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> PhyneModuleIr:
        funcs: list[PhyneFunctionSpec] = []
        for fn in raw.get("functions", []):
            params = [
                PhyneParamSpec(
                    name=str(p["name"]),
                    nim_type=str(p["nim_type"]),
                    c_type=str(p["c_type"]),
                    py_type=str(p["py_type"]),
                )
                for p in fn.get("params", [])
            ]
            funcs.append(
                PhyneFunctionSpec(
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
    def from_json(cls, json_str: str) -> PhyneModuleIr:
        return cls.from_dict(json.loads(json_str))


class PhyneWriterPlugin:
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
} phyne_buf_view_t;

int phyne_init_runtime(void);
int phyne_shutdown_runtime(void);
void phyne_clear_error(void);
const char* phyne_last_error(void);
void phyne_set_last_error(const char* msg);
int phyne_flush_deferred_decrefs(void);
int phyne_deferred_decref_count(void);
void phyne_buf_release(phyne_buf_view_t* view);
const char* phyne_module_ir_json(void);

void* phyne_async_bridge_create(int num_workers);
void phyne_async_bridge_destroy(void* bridge_ptr);
int phyne_async_bridge_read_fd(void* bridge_ptr);
int phyne_async_drain_wakeup(void* bridge_ptr);
int phyne_async_pop_completion(
    void* bridge_ptr,
    uint64_t* out_future_id,
    int* out_status,
    int64_t* out_int,
    double* out_float,
    const char** out_str
);
int phyne_async_submit_compute(
    void* bridge_ptr,
    uint64_t future_id,
    int op_code,
    int64_t arg_a,
    int64_t arg_b
);
int phyne_async_channel_push_int(void* bridge_ptr, uint64_t channel_id, int64_t val);
int phyne_async_channel_close(void* bridge_ptr, uint64_t channel_id);
""".strip()

    def __init__(self, ir: PhyneModuleIr) -> None:
        self.ir = ir

    @classmethod
    def from_ir_file(cls, path: str | Path) -> PhyneWriterPlugin:
        text = Path(path).read_text(encoding="utf-8")
        return cls(PhyneModuleIr.from_json(text))

    @classmethod
    def from_ir_json(cls, json_str: str) -> PhyneWriterPlugin:
        return cls(PhyneModuleIr.from_json(json_str))

    def generate_pyi_stub(self) -> str:
        lines: list[str] = [
            f"# Auto-generated PEP 484 stub for phyne module `{self.ir.module}`",
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
