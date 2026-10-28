## Dual-Target `{.exportpy.}` Macro, PEP 489 Module Initialization & IR Metadata Generator.
##
## Implements `design.md` §3.4:
## - `{.exportpy.}` / `{.pyexport.}` macro generating:
##   1. CPython `abi3` / `abi3t` `PyCFunction` wrapper (`phyne_py_<name>`) guarded by `pyAbiBoundary`
##   2. CFFI C-ABI wrapper (`phyne_c_<name>`) guarded by `cAbiBoundary` returning `cint` status code
## - Compile-time IR metadata registry (`PhyneProcIr`, `phyneModuleIrJson`) for `writer_plugin.py`
## - PEP 489 multi-phase `PyModuleDef_Init` with `Py_mod_gil = Py_MOD_GIL_NOT_USED` (`abi3t` ready)

import std/[macros, strutils]
import ./abi
import ./lifecycle
import ./gc_bridge
import ./conversions
import ./buffer

type
  PhyneParamIr* = object
    name*: string
    nimType*: string
    cType*: string
    pyType*: string

  PhyneProcIr* = object
    name*: string
    cSymbol*: string
    pySymbol*: string
    doc*: string
    params*: seq[PhyneParamIr]
    returnNimType*: string
    returnCType*: string
    returnPyType*: string
    hasCAbi*: bool

  PhyneMethodEntry* = object
    name*: string
    doc*: string
    fn*: PyCFunction

var gRegisteredMethods*: seq[PhyneMethodEntry] = @[]
var gRegisteredIr*: seq[PhyneProcIr] = @[]
var gCAbiStringReturnBuf* {.threadvar.}: string
var gModuleIrCache* {.threadvar.}: string

proc registerPhyneExport*(
  name: string,
  cSymbol: string,
  pySymbol: string,
  doc: string,
  params: openArray[PhyneParamIr],
  returnNimType: string,
  returnCType: string,
  returnPyType: string,
  hasCAbi: bool,
  fn: PyCFunction
) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    gRegisteredMethods.add(PhyneMethodEntry(name: name, doc: doc, fn: fn))
    gRegisteredIr.add(PhyneProcIr(
      name: name,
      cSymbol: cSymbol,
      pySymbol: pySymbol,
      doc: doc,
      params: @params,
      returnNimType: returnNimType,
      returnCType: returnCType,
      returnPyType: returnPyType,
      hasCAbi: hasCAbi
    ))

proc jsonEscape(s: string): string {.gcsafe, raises: [].} =
  result = "\""
  for ch in s:
    case ch
    of '\"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)
  result.add("\"")

proc buildPhyneIrJson*(moduleName: string): string {.gcsafe, raises: [].} =
  result = "{\n  \"module\": " & jsonEscape(moduleName) & ",\n  \"functions\": [\n"
  {.cast(gcsafe).}:
    for i, fn in gRegisteredIr:
      if i > 0:
        result.add(",\n")
      result.add("    {\n")
      result.add("      \"name\": " & jsonEscape(fn.name) & ",\n")
      result.add("      \"c_symbol\": " & jsonEscape(fn.cSymbol) & ",\n")
      result.add("      \"py_symbol\": " & jsonEscape(fn.pySymbol) & ",\n")
      result.add("      \"doc\": " & jsonEscape(fn.doc) & ",\n")
      result.add("      \"has_c_abi\": " & (if fn.hasCAbi: "true" else: "false") & ",\n")
      result.add("      \"return_nim_type\": " & jsonEscape(fn.returnNimType) & ",\n")
      result.add("      \"return_c_type\": " & jsonEscape(fn.returnCType) & ",\n")
      result.add("      \"return_py_type\": " & jsonEscape(fn.returnPyType) & ",\n")
      result.add("      \"params\": [")
      for j, p in fn.params:
        if j > 0:
          result.add(", ")
        result.add(
          "{\"name\": " & jsonEscape(p.name) &
          ", \"nim_type\": " & jsonEscape(p.nimType) &
          ", \"c_type\": " & jsonEscape(p.cType) &
          ", \"py_type\": " & jsonEscape(p.pyType) & "}"
        )
      result.add("]\n    }")
  result.add("\n  ]\n}\n")

proc splitTopLevelComma(s: string): seq[string] {.compileTime.} =
  var depth = 0
  var startIdx = 0
  for i, ch in s:
    case ch
    of '[', '(', '{':
      inc depth
    of ']', ')', '}':
      if depth > 0:
        dec depth
    of ',':
      if depth == 0:
        result.add(s[startIdx ..< i].strip())
        startIdx = i + 1
    else:
      discard
  result.add(s[startIdx .. ^1].strip())

proc mapTypeToPyStub*(nimType: string): string {.compileTime.} =
  let t = nimType.strip()
  case t
  of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64":
    "int"
  of "float", "float32", "float64":
    "float"
  of "bool":
    "bool"
  of "string", "cstring":
    "str"
  of "seq[byte]":
    "bytes"
  of "", "void":
    "None"
  else:
    if t.startsWith("seq["):
      let inner = t[4 .. ^2]
      "list[" & mapTypeToPyStub(inner) & "]"
    elif t.startsWith("Option["):
      let inner = t[7 .. ^2]
      mapTypeToPyStub(inner) & " | None"
    elif t.startsWith("Table["):
      let inner = t[6 .. ^2]
      let parts = splitTopLevelComma(inner)
      if parts.len == 2:
        "dict[" & mapTypeToPyStub(parts[0]) & ", " & mapTypeToPyStub(parts[1]) & "]"
      else:
        "dict[Any, Any]"
    elif t.startsWith("PinnedBuffer[") or t.startsWith("ScopedSeqBuffer["):
      "memoryview"
    else:
      "Any"

proc mapTypeToCSig(nimType: string): (bool, string) {.compileTime.} =
  let t = nimType.strip()
  case t
  of "int", "int64":
    (true, "int64_t")
  of "int32":
    (true, "int32_t")
  of "int16":
    (true, "int16_t")
  of "int8":
    (true, "int8_t")
  of "uint", "uint64":
    (true, "uint64_t")
  of "uint32":
    (true, "uint32_t")
  of "uint16":
    (true, "uint16_t")
  of "uint8", "byte":
    (true, "uint8_t")
  of "float", "float64":
    (true, "double")
  of "float32":
    (true, "float")
  of "bool":
    (true, "bool")
  of "string", "cstring":
    (true, "const char*")
  of "", "void":
    (true, "void")
  else:
    if t.startsWith("PinnedBuffer["):
      (true, "phyne_buf_view_t")
    else:
      (false, "")

proc extractDocstring(body: NimNode): string {.compileTime.} =
  if body.kind == nnkStmtList and body.len > 0 and body[0].kind == nnkCommentStmt:
    return body[0].strVal.strip()
  return ""

macro exportpy*(procDef: untyped): untyped =
  ## Dual-target export macro:
  ## 1. Emits original Nim proc
  ## 2. Emits `phyne_py_<name>` (`PyCFunction` for `abi3` / `abi3t`)
  ## 3. Emits `phyne_c_<name>` (`cdecl` C-ABI for `cffi` when types map to C primitives/strings/PinnedBuffer)
  ## 4. Registers metadata for `.phyne.ir.json` and PEP 489 module table
  expectKind(procDef, {nnkProcDef, nnkFuncDef})
  let rawNameNode = procDef.name
  let baseName =
    if rawNameNode.kind == nnkPostfix:
      rawNameNode[1].strVal
    else:
      rawNameNode.strVal

  let pySymStr = "phyne_py_" & baseName
  let cSymStr = "phyne_c_" & baseName
  let pyWrapperIdent = ident(pySymStr)
  let cWrapperIdent = ident(cSymStr)
  let registerProcIdent = ident("phyne_register_" & baseName)
  let procCallIdent = ident(baseName)

  let formalParams = procDef.params
  let retTypeNode = formalParams[0]
  let hasReturn = retTypeNode.kind != nnkEmpty and repr(retTypeNode).strip() != "void"
  let retNimStr = if hasReturn: repr(retTypeNode).strip() else: "void"
  let (retCOk, retCStr) = mapTypeToCSig(retNimStr)
  let retPyStr = mapTypeToPyStub(retNimStr)

  var paramNames: seq[NimNode] = @[]
  var paramTypes: seq[NimNode] = @[]
  var paramNimStrs: seq[string] = @[]
  var paramCStrs: seq[string] = @[]
  var paramPyStrs: seq[string] = @[]
  var allCCompatible = retCOk

  for i in 1 ..< formalParams.len:
    let idDefs = formalParams[i]
    let pType = idDefs[^2]
    let pTypeStr = repr(pType).strip()
    let (cOk, cStr) = mapTypeToCSig(pTypeStr)
    if not cOk or pTypeStr.startsWith("PinnedBuffer["):
      allCCompatible = false
    for j in 0 ..< idDefs.len - 2:
      let pName = idDefs[j]
      paramNames.add(if pName.kind == nnkPostfix: pName[1] else: pName)
      paramTypes.add(pType)
      paramNimStrs.add(pTypeStr)
      paramCStrs.add(cStr)
      paramPyStrs.add(mapTypeToPyStub(pTypeStr))

  let arity = paramNames.len
  let docStr = extractDocstring(procDef.body)

  # Build PyCFunction wrapper body
  let selfIdent = ident("self")
  let argsIdent = ident("args")
  var pyUnpackStmts = newStmtList()
  var callArgs: seq[NimNode] = @[]

  for idx in 0 ..< arity:
    let argVar = ident("arg_" & $idx)
    let pType = paramTypes[idx]
    let idxLit = newLit(idx)
    pyUnpackStmts.add quote do:
      let rawItem = PyTuple_GetItem(`argsIdent`, Py_ssize_t(`idxLit`))
      if rawItem.isNil:
        raise newException(PhyneConversionError, "Failed to extract argument " & $`idxLit`)
      let `argVar` = fromPyRaw(rawItem, `pType`)
    callArgs.add(argVar)

  let nimCallExpr = newCall(procCallIdent, callArgs)
  let pyExecStmt =
    if hasReturn:
      quote do:
        let nimRes = `nimCallExpr`
        toPyRaw(nimRes)
    else:
      quote do:
        `nimCallExpr`
        pyNewNone()

  let arityLit = newLit(arity)
  let fnNameLit = newLit(baseName)

  let pyWrapperProc = quote do:
    proc `pyWrapperIdent`*(`selfIdent`: PyObjectPtr, `argsIdent`: PyObjectPtr): PyObjectPtr {.exportc: `pySymStr`, cdecl, dynlib, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        pyAbiBoundary:
          let actualArity = if `argsIdent`.isNil: 0 else: int(PyTuple_Size(`argsIdent`))
          if actualArity != `arityLit`:
            raise newException(
              PhyneConversionError,
              `fnNameLit` & "() takes exactly " & $`arityLit` & " argument(s) (" & $actualArity & " given)"
            )
          `pyUnpackStmts`
          `pyExecStmt`

  # Build C-ABI wrapper if all parameters and return type are C-compatible
  var cWrapperStmt = newStmtList()
  if allCCompatible:
    var cParams: seq[NimNode] = @[ident("cint")]
    var cCallArgs: seq[NimNode] = @[]
    for idx in 0 ..< arity:
      let pName = ident("c_arg_" & $idx)
      let pNimStr = paramNimStrs[idx]
      if pNimStr == "string":
        cParams.add(newIdentDefs(pName, ident("cstring")))
        cCallArgs.add(quote do: (if `pName`.isNil: "" else: $`pName`))
      else:
        cParams.add(newIdentDefs(pName, paramTypes[idx]))
        cCallArgs.add(pName)

    let outPtrIdent = ident("out_res")
    if hasReturn:
      if retNimStr == "string":
        cParams.add(newIdentDefs(outPtrIdent, nnkPtrTy.newTree(ident("cstring"))))
      elif retNimStr.startsWith("PinnedBuffer["):
        cParams.add(newIdentDefs(outPtrIdent, nnkPtrTy.newTree(ident("phyne_buf_view_t"))))
      else:
        cParams.add(newIdentDefs(outPtrIdent, nnkPtrTy.newTree(retTypeNode)))

    let cNimCall = newCall(procCallIdent, cCallArgs)
    let cBodyInner =
      if not hasReturn:
        quote do:
          `cNimCall`
      elif retNimStr == "string":
        quote do:
          gCAbiStringReturnBuf = `cNimCall`
          if not `outPtrIdent`.isNil:
            `outPtrIdent`[] = cstring(gCAbiStringReturnBuf)
      elif retNimStr.startsWith("PinnedBuffer["):
        quote do:
          let pinnedRes = `cNimCall`
          if not `outPtrIdent`.isNil:
            `outPtrIdent`[] = pinnedRes.toBufView()
      else:
        quote do:
          let scalarRes = `cNimCall`
          if not `outPtrIdent`.isNil:
            `outPtrIdent`[] = scalarRes

    let cExportPragma = nnkPragma.newTree(
      nnkExprColonExpr.newTree(ident("exportc"), newLit(cSymStr)),
      ident("cdecl"),
      ident("dynlib"),
      ident("gcsafe"),
      nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree())
    )
    let cBodyFull = quote do:
      {.cast(gcsafe).}:
        cAbiBoundary:
          `cBodyInner`

    cWrapperStmt.add newProc(
      name = nnkPostfix.newTree(ident("*"), cWrapperIdent),
      params = cParams,
      body = cBodyFull,
      procType = nnkProcDef,
      pragmas = cExportPragma
    )

  # Build IR registration array
  var irParamBracket = nnkBracket.newTree()
  for idx in 0 ..< arity:
    let pNameStr = paramNames[idx].strVal
    let pNim = paramNimStrs[idx]
    let pC = paramCStrs[idx]
    let pPy = paramPyStrs[idx]
    irParamBracket.add quote do:
      PhyneParamIr(name: `pNameStr`, nimType: `pNim`, cType: `pC`, pyType: `pPy`)

  let docLit = newLit(docStr)
  let retNimLit = newLit(retNimStr)
  let retCLit = newLit(retCStr)
  let retPyLit = newLit(retPyStr)
  let hasCAbiLit = newLit(allCCompatible)
  let cSymLit = newLit(cSymStr)
  let pySymLit = newLit(pySymStr)

  let regStmt = quote do:
    proc `registerProcIdent`() {.gcsafe, raises: [].} =
      registerPhyneExport(
        name = `fnNameLit`,
        cSymbol = `cSymLit`,
        pySymbol = `pySymLit`,
        doc = `docLit`,
        params = @`irParamBracket`,
        returnNimType = `retNimLit`,
        returnCType = `retCLit`,
        returnPyType = `retPyLit`,
        hasCAbi = `hasCAbiLit`,
        fn = `pyWrapperIdent`
      )
    `registerProcIdent`()

  result = newStmtList(procDef, pyWrapperProc, cWrapperStmt, regStmt)

template pyexport*(procDef: untyped): untyped =
  exportpy(procDef)

# ---------------------------------------------------------------------------
# PEP 489 Multi-Phase Module Initialization Macro (`phyneInitModule`)
# ---------------------------------------------------------------------------
template phyneInitModule*(moduleName: static[string], moduleDoc: static[string] = "") =
  var gModuleMethods {.global.}: seq[PyMethodDef]
  var gModuleSlots {.global.}: array[3, PyModuleDef_Slot]
  var gModuleDef {.global.}: PyModuleDef
  var gModuleDefFT {.global.}: PyModuleDef_FT
  var gModuleInitialized {.global.}: bool = false
  var gModuleIsFT {.global.}: bool = false

  proc phyneModuleExec(m: PyObjectPtr): cint {.cdecl, gcsafe, raises: [].} =
    discard phyne_init_runtime()
    discard PyModule_AddStringConstant(m, "__phyne_ir__", cstring(buildPhyneIrJson(moduleName)))
    return 0

  proc phyne_module_ir_json*(): cstring {.exportc: "phyne_module_ir_json", cdecl, dynlib, gcsafe, raises: [].} =
    discard phyne_init_runtime()
    gModuleIrCache = buildPhyneIrJson(moduleName)
    return cstring(gModuleIrCache)

  proc PyInit_module*(): PyObjectPtr {.exportc: "PyInit_" & moduleName, cdecl, dynlib, gcsafe, raises: [].} =
    discard phyne_init_runtime()
    {.cast(gcsafe).}:
      if not gModuleInitialized:
        gModuleMethods.setLen(gRegisteredMethods.len + 1)
        for i in 0 ..< gRegisteredMethods.len:
          gModuleMethods[i] = PyMethodDef(
            ml_name: cstring(gRegisteredMethods[i].name),
            ml_meth: gRegisteredMethods[i].fn,
            ml_flags: METH_VARARGS,
            ml_doc: cstring(gRegisteredMethods[i].doc)
          )
        gModuleMethods[gRegisteredMethods.len] = PyMethodDef(
          ml_name: nil,
          ml_meth: nil,
          ml_flags: 0,
          ml_doc: nil
        )
        gModuleSlots[0] = PyModuleDef_Slot(
          slot: Py_mod_exec,
          value: cast[pointer](phyneModuleExec)
        )
        # PEP 703 free-threading support: declare module safe without GIL
        gModuleSlots[1] = PyModuleDef_Slot(
          slot: Py_mod_gil,
          value: Py_MOD_GIL_NOT_USED
        )
        gModuleSlots[2] = PyModuleDef_Slot(slot: 0, value: nil)
        gModuleIsFT = isFreeThreadedRuntime()
        if gModuleIsFT:
          gModuleDefFT = PyModuleDef_FT(
            m_base: PyModuleDef_Base_FT(
              ob_base: PyObject_FT(
                ob_tid: 0,
                ob_flags: 0,
                ob_mutex: 0,
                ob_gc_bits: 0,
                ob_ref_local: 0xFFFFFFFF'u32,
                ob_ref_shared: 0,
                ob_type: nil
              ),
              m_init: nil,
              m_index: 0,
              m_copy: nil
            ),
            m_name: cstring(moduleName),
            m_doc: cstring(moduleDoc),
            m_size: 0,
            m_methods: if gModuleMethods.len > 0: addr gModuleMethods[0] else: nil,
            m_slots: addr gModuleSlots[0],
            m_traverse: nil,
            m_clear: nil,
            m_free: nil
          )
        else:
          gModuleDef = PyModuleDef(
            m_base: PyModuleDef_Base(
              ob_base: PyObject(ob_refcnt: 1, ob_type: nil),
              m_init: nil,
              m_index: 0,
              m_copy: nil
            ),
            m_name: cstring(moduleName),
            m_doc: cstring(moduleDoc),
            m_size: 0,
            m_methods: if gModuleMethods.len > 0: addr gModuleMethods[0] else: nil,
            m_slots: addr gModuleSlots[0],
            m_traverse: nil,
            m_clear: nil,
            m_free: nil
          )
        gModuleInitialized = true
      if gModuleIsFT:
        return PyModuleDef_Init(cast[ptr PyModuleDef](addr gModuleDefFT))
      else:
        return PyModuleDef_Init(addr gModuleDef)
