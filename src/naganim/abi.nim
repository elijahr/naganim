## Direct CPython 3.12+ Limited C-ABI (abi3 / PEP 803 abi3t) Bindings.
##
## Declares stable ABI symbols using direct `{.importc, cdecl.}` bindings
## without `#include <Python.h>` preprocessor macro collisions (MED-01).

import std/atomics

type
  Py_ssize_t* = int
  Py_hash_t* = int

  PyObject* {.pure, inheritable.} = object
    ob_refcnt*: Py_ssize_t
    ob_type*: pointer

  PyObjectPtr* = ptr PyObject

  PyCFunction* = proc(self: PyObjectPtr, args: PyObjectPtr): PyObjectPtr {.cdecl, gcsafe, raises: [].}
  PyCFunctionWithKeywords* = proc(self: PyObjectPtr, args: PyObjectPtr, kwargs: PyObjectPtr): PyObjectPtr {.cdecl, gcsafe, raises: [].}
  destructor* = proc(self: PyObjectPtr) {.cdecl, gcsafe, raises: [].}
  getbufferproc* = proc(self: PyObjectPtr, view: ptr Py_buffer, flags: cint): cint {.cdecl, gcsafe, raises: [].}
  releasebufferproc* = proc(self: PyObjectPtr, view: ptr Py_buffer) {.cdecl, gcsafe, raises: [].}
  PyCapsule_Destructor* = proc(capsule: PyObjectPtr) {.cdecl, gcsafe, raises: [].}

  PyMethodDef* {.pure.} = object
    ml_name*: cstring
    ml_meth*: PyCFunction
    ml_flags*: cint
    ml_doc*: cstring

  PyModuleDef_Base* {.pure.} = object
    ob_base*: PyObject
    m_init*: pointer
    m_index*: Py_ssize_t
    m_copy*: PyObjectPtr

  PyModuleDef_Slot* {.pure.} = object
    slot*: cint
    value*: pointer

  PyModuleDef* {.pure.} = object
    m_base*: PyModuleDef_Base
    m_name*: cstring
    m_doc*: cstring
    m_size*: Py_ssize_t
    m_methods*: ptr PyMethodDef
    m_slots*: ptr PyModuleDef_Slot
    m_traverse*: pointer
    m_clear*: pointer
    m_free*: pointer

  PyObject_FT* {.pure.} = object
    ob_tid*: uint
    ob_flags*: uint16
    ob_mutex*: uint8
    ob_gc_bits*: uint8
    ob_ref_local*: uint32
    ob_ref_shared*: Py_ssize_t
    ob_type*: pointer

  PyModuleDef_Base_FT* {.pure.} = object
    ob_base*: PyObject_FT
    m_init*: pointer
    m_index*: Py_ssize_t
    m_copy*: PyObjectPtr

  PyModuleDef_FT* {.pure.} = object
    m_base*: PyModuleDef_Base_FT
    m_name*: cstring
    m_doc*: cstring
    m_size*: Py_ssize_t
    m_methods*: ptr PyMethodDef
    m_slots*: ptr PyModuleDef_Slot
    m_traverse*: pointer
    m_clear*: pointer
    m_free*: pointer

  PyType_Slot* {.pure.} = object
    slot*: cint
    pfunc*: pointer

  PyType_Spec* {.pure.} = object
    name*: cstring
    basicsize*: cint
    itemsize*: cint
    flags*: cuint
    slots*: ptr PyType_Slot

  Py_buffer* {.pure.} = object
    buf*: pointer
    obj*: PyObjectPtr
    len*: Py_ssize_t
    itemsize*: Py_ssize_t
    readonly*: cint
    ndim*: cint
    format*: cstring
    shape*: ptr Py_ssize_t
    strides*: ptr Py_ssize_t
    suboffsets*: ptr Py_ssize_t
    internal*: pointer

  PyGILState_STATE* = cint

const
  # Method flags
  METH_VARARGS* = cint(0x0001)
  METH_KEYWORDS* = cint(0x0002)
  METH_NOARGS* = cint(0x0004)
  METH_O* = cint(0x0008)
  METH_FASTCALL* = cint(0x0080)

  # PEP 489 / PEP 684 / PEP 703 Module slots
  Py_mod_create* = cint(1)
  Py_mod_exec* = cint(2)
  Py_mod_multiple_interpreters* = cint(3)
  Py_mod_gil* = cint(4)

  # Py_mod_gil values (PEP 703 free-threading)
  Py_MOD_GIL_USED* = cast[pointer](0)
  Py_MOD_GIL_NOT_USED* = cast[pointer](1)

  # Py_mod_multiple_interpreters values (PEP 684)
  Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED* = cast[pointer](0)
  Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED* = cast[pointer](1)
  Py_MOD_PER_INTERPRETER_GIL_SUPPORTED* = cast[pointer](2)

  # Type flags
  Py_TPFLAGS_DEFAULT* = cuint(0)
  Py_TPFLAGS_Managed_WEAKREF* = cuint(1 shl 3)
  Py_TPFLAGS_MANAGED_DICT* = cuint(1 shl 4)
  Py_TPFLAGS_HEAPTYPE* = cuint(1 shl 9)
  Py_TPFLAGS_BASETYPE* = cuint(1 shl 10)
  Py_TPFLAGS_IMMUTABLETYPE* = cuint(1 shl 8)

  # PEP 384 Type slots
  Py_bf_getbuffer* = cint(1)
  Py_bf_releasebuffer* = cint(2)
  Py_tp_dealloc* = cint(52)
  Py_tp_doc* = cint(56)
  Py_tp_methods* = cint(64)
  Py_tp_new* = cint(65)
  Py_tp_free* = cint(74)

  # Buffer protocol flags (PEP 3118)
  PyBUF_SIMPLE* = cint(0)
  PyBUF_WRITABLE* = cint(0x0001)
  PyBUF_FORMAT* = cint(0x0004)
  PyBUF_ND* = cint(0x0008)
  PyBUF_STRIDES* = cint(0x0010 or PyBUF_ND)
  PyBUF_C_CONTIGUOUS* = cint(0x0020 or PyBUF_STRIDES)
  PyBUF_F_CONTIGUOUS* = cint(0x0040 or PyBUF_STRIDES)
  PyBUF_ANY_CONTIGUOUS* = cint(0x0080 or PyBUF_STRIDES)
  PyBUF_INDIRECT* = cint(0x0100 or PyBUF_STRIDES)
  PyBUF_CONTIG* = cint(PyBUF_ND or PyBUF_WRITABLE)
  PyBUF_CONTIG_RO* = cint(PyBUF_ND)
  PyBUF_STRIDED* = cint(PyBUF_STRIDES or PyBUF_WRITABLE)
  PyBUF_STRIDED_RO* = cint(PyBUF_STRIDES)
  PyBUF_RECORDS* = cint(PyBUF_STRIDES or PyBUF_WRITABLE or PyBUF_FORMAT)
  PyBUF_RECORDS_RO* = cint(PyBUF_STRIDES or PyBUF_FORMAT)
  PyBUF_FULL* = cint(PyBUF_INDIRECT or PyBUF_WRITABLE or PyBUF_FORMAT)
  PyBUF_FULL_RO* = cint(PyBUF_INDIRECT or PyBUF_FORMAT)

  # MemoryView access flags
  PyBUF_READ* = cint(0x100)
  PyBUF_WRITE* = cint(0x200)

  # Rich comparison opcodes
  Py_LT* = cint(0)
  Py_LE* = cint(1)
  Py_EQ* = cint(2)
  Py_NE* = cint(3)
  Py_GT* = cint(4)
  Py_GE* = cint(5)

# ---------------------------------------------------------------------------
# Runtime Initialization & GIL / Thread State
# ---------------------------------------------------------------------------
proc Py_IsInitialized*(): cint {.importc, cdecl, gcsafe, raises: [].}
proc Py_InitializeEx*(initsigs: cint) {.importc, cdecl, gcsafe, raises: [].}
proc Py_FinalizeEx*(): cint {.importc, cdecl, gcsafe, raises: [].}

proc PyGILState_Check*(): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyGILState_Ensure*(): PyGILState_STATE {.importc, cdecl, gcsafe, raises: [].}
proc PyGILState_Release*(state: PyGILState_STATE) {.importc, cdecl, gcsafe, raises: [].}

proc PyEval_SaveThread*(): pointer {.importc, cdecl, gcsafe, raises: [].}
proc PyEval_RestoreThread*(tstate: pointer) {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Reference Counting (Functional ABI — works on both abi3 and PEP 803 abi3t)
# ---------------------------------------------------------------------------
proc Py_IncRef*(o: PyObjectPtr) {.importc, cdecl, gcsafe, raises: [].}
proc Py_DecRef*(o: PyObjectPtr) {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Module & Type Creation (PEP 489 & PEP 384)
# ---------------------------------------------------------------------------
proc PyModuleDef_Init*(def: ptr PyModuleDef): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyModule_Create2*(def: ptr PyModuleDef, apiver: cint): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyModule_AddObjectRef*(module: PyObjectPtr, name: cstring, value: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyModule_AddObject*(module: PyObjectPtr, name: cstring, value: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyModule_AddIntConstant*(module: PyObjectPtr, name: cstring, value: clong): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyModule_AddStringConstant*(module: PyObjectPtr, name: cstring, value: cstring): cint {.importc, cdecl, gcsafe, raises: [].}

proc PyType_FromSpec*(spec: ptr PyType_Spec): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyType_FromModuleAndSpec*(module: PyObjectPtr, spec: ptr PyType_Spec, bases: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyType_GenericNew*(tp: PyObjectPtr, args: PyObjectPtr, kwds: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_Free*(p: pointer) {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Standard Exception Pointers & Error API
# ---------------------------------------------------------------------------
var
  PyExc_Exception* {.importc.}: PyObjectPtr
  PyExc_RuntimeError* {.importc.}: PyObjectPtr
  PyExc_ValueError* {.importc.}: PyObjectPtr
  PyExc_TypeError* {.importc.}: PyObjectPtr
  PyExc_IndexError* {.importc.}: PyObjectPtr
  PyExc_KeyError* {.importc.}: PyObjectPtr
  PyExc_MemoryError* {.importc.}: PyObjectPtr
  PyExc_BufferError* {.importc.}: PyObjectPtr
  PyExc_StopIteration* {.importc.}: PyObjectPtr
  PyExc_OverflowError* {.importc.}: PyObjectPtr

proc PyErr_SetString*(exc: PyObjectPtr, message: cstring) {.importc, cdecl, gcsafe, raises: [].}
proc PyErr_Occurred*(): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyErr_Clear*() {.importc, cdecl, gcsafe, raises: [].}
proc PyErr_Fetch*(ptype: ptr PyObjectPtr, pvalue: ptr PyObjectPtr, ptraceback: ptr PyObjectPtr) {.importc, cdecl, gcsafe, raises: [].}
proc PyErr_Restore*(ptype: PyObjectPtr, pvalue: PyObjectPtr, ptraceback: PyObjectPtr) {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Primitives: None, Bool, Long, Float
# ---------------------------------------------------------------------------
proc Py_BuildValue*(format: cstring): PyObjectPtr {.importc, cdecl, varargs, gcsafe, raises: [].}

var
  gPyNoneSingleton: Atomic[pointer]
  gFreeThreadedRuntimeState*: Atomic[int32] # 0 = unprobed, 1 = standard GIL, 2 = PEP 703 free-threaded

proc getCachedPyNone*(): PyObjectPtr {.inline, gcsafe, raises: [].} =
  var n = cast[PyObjectPtr](gPyNoneSingleton.load(moAcquire))
  if unlikely(n.isNil):
    let built = Py_BuildValue("")
    if not built.isNil:
      gPyNoneSingleton.store(cast[pointer](built), moRelease)
      Py_DecRef(built)
      n = built
  return n

proc pyNewNone*(): PyObjectPtr {.inline, gcsafe, raises: [].} =
  ## Returns a new reference to Py_None using only the stable function ABI.
  let n = getCachedPyNone()
  if not n.isNil:
    Py_IncRef(n)
    return n
  Py_BuildValue("")

proc pyIsNone*(obj: PyObjectPtr): bool {.inline, gcsafe, raises: [].} =
  if obj.isNil:
    return false
  let noneObj = getCachedPyNone()
  if noneObj.isNil:
    return false
  return obj == noneObj

proc PyLong_FromLongLong*(v: clonglong): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyLong_AsLongLong*(obj: PyObjectPtr): clonglong {.importc, cdecl, gcsafe, raises: [].}
proc PyLong_FromUnsignedLongLong*(v: culonglong): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyLong_AsUnsignedLongLong*(obj: PyObjectPtr): culonglong {.importc, cdecl, gcsafe, raises: [].}

proc PyFloat_FromDouble*(v: cdouble): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyFloat_AsDouble*(obj: PyObjectPtr): cdouble {.importc, cdecl, gcsafe, raises: [].}

proc PyBool_FromLong*(v: clong): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_IsTrue*(obj: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}

proc isFreeThreadedRuntime*(): bool {.inline, gcsafe, raises: [].} =
  ## Detects at runtime whether the active CPython interpreter uses the 32-byte
  ## Free-Threaded (PEP 703 / Py_GIL_DISABLED) PyObject header vs the 16-byte
  ## standard GIL PyObject header, caching the result atomically.
  let cached = gFreeThreadedRuntimeState.load(moAcquire)
  if likely(cached != 0'i32):
    return cached == 2'i32
  when sizeof(pointer) == 8:
    let t = PyBool_FromLong(1)
    let f = PyBool_FromLong(0)
    if t.isNil or f.isNil:
      return false
    let tWords = cast[ptr UncheckedArray[uint64]](t)
    let fWords = cast[ptr UncheckedArray[uint64]](f)
    result = (tWords[3] == fWords[3]) and (tWords[3] != 0'u64)
    Py_DecRef(t)
    Py_DecRef(f)
  else:
    result = false
  gFreeThreadedRuntimeState.store(if result: 2'i32 else: 1'i32, moRelease)

proc pyTypeOf*(obj: PyObjectPtr): PyObjectPtr {.inline, gcsafe, raises: [].} =
  ## Reads `Py_TYPE(obj)` (`ob_type`) across both standard 16-byte `abi3` headers
  ## and 32-byte Free-Threaded (`3.13t`/`3.14t` PEP 703) `PyObject_FT` headers.
  if obj.isNil:
    return nil
  if isFreeThreadedRuntime():
    let ft = cast[ptr PyObject_FT](obj)
    return cast[PyObjectPtr](ft.ob_type)
  else:
    return cast[PyObjectPtr](obj.ob_type)

proc pyRawRefCount*(obj: PyObjectPtr): int {.inline, gcsafe, raises: [].} =
  ## Reads the effective reference count of `obj` across both standard GIL builds
  ## (`ob_refcnt` at offset 0) and Free-Threaded Python `3.13t`/`3.14t` PEP 703
  ## builds (`ob_ref_local + (ob_ref_shared shr 2)` inside `PyObject_FT`).
  if obj.isNil:
    return 0
  if isFreeThreadedRuntime():
    let ft = cast[ptr PyObject_FT](obj)
    let localRc = ft.ob_ref_local
    let sharedRc = int(ft.ob_ref_shared shr 2)
    if localRc == 0xFFFFFFFF'u32:
      return int(0x3FFFFFFF) + sharedRc
    return int(localRc) + sharedRc
  else:
    return int(obj[].ob_refcnt)

# ---------------------------------------------------------------------------
# Strings (Unicode) & Bytes
# ---------------------------------------------------------------------------
proc PyUnicode_FromStringAndSize*(u: cstring, size: Py_ssize_t): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyUnicode_AsUTF8AndSize*(unicode: PyObjectPtr, size: ptr Py_ssize_t): cstring {.importc, cdecl, gcsafe, raises: [].}

proc PyBytes_FromStringAndSize*(v: pointer, len: Py_ssize_t): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyBytes_AsStringAndSize*(obj: PyObjectPtr, s: ptr pointer, len: ptr Py_ssize_t): cint {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Containers: Tuple, List, Dict
# ---------------------------------------------------------------------------
proc PyTuple_New*(len: Py_ssize_t): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyTuple_Size*(p: PyObjectPtr): Py_ssize_t {.importc, cdecl, gcsafe, raises: [].}
proc PyTuple_GetItem*(p: PyObjectPtr, pos: Py_ssize_t): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyTuple_SetItem*(p: PyObjectPtr, pos: Py_ssize_t, o: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}

proc PyList_New*(len: Py_ssize_t): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyList_Size*(p: PyObjectPtr): Py_ssize_t {.importc, cdecl, gcsafe, raises: [].}
proc PyList_GetItem*(p: PyObjectPtr, index: Py_ssize_t): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyList_SetItem*(p: PyObjectPtr, index: Py_ssize_t, item: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyList_Append*(p: PyObjectPtr, item: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}

proc PyDict_New*(): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyDict_Size*(p: PyObjectPtr): Py_ssize_t {.importc, cdecl, gcsafe, raises: [].}
proc PyDict_GetItem*(p: PyObjectPtr, key: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyDict_SetItem*(p: PyObjectPtr, key: PyObjectPtr, val: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyDict_GetItemString*(p: PyObjectPtr, key: cstring): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyDict_SetItemString*(p: PyObjectPtr, key: cstring, val: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyDict_Next*(p: PyObjectPtr, ppos: ptr Py_ssize_t, pkey: ptr PyObjectPtr, pvalue: ptr PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Generic Object Protocol & Calls
# ---------------------------------------------------------------------------
proc PyObject_Str*(o: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_Repr*(o: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_GetAttrString*(o: PyObjectPtr, attr_name: cstring): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_SetAttrString*(o: PyObjectPtr, attr_name: cstring, v: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_HasAttrString*(o: PyObjectPtr, attr_name: cstring): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_Call*(callable: PyObjectPtr, args: PyObjectPtr, kwargs: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_CallObject*(callable: PyObjectPtr, args: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_CallNoArgs*(callable: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_CallOneArg*(callable: PyObjectPtr, arg: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_RichCompareBool*(o1: PyObjectPtr, o2: PyObjectPtr, opid: cint): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyCallable_Check*(o: PyObjectPtr): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyImport_ImportModule*(name: cstring): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# Buffer Protocol & MemoryView (PEP 3118)
# ---------------------------------------------------------------------------
proc PyMemoryView_FromMemory*(mem: pointer, size: Py_ssize_t, flags: cint): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyMemoryView_FromObject*(base: PyObjectPtr): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyObject_GetBuffer*(exporter: PyObjectPtr, view: ptr Py_buffer, flags: cint): cint {.importc, cdecl, gcsafe, raises: [].}
proc PyBuffer_Release*(view: ptr Py_buffer) {.importc, cdecl, gcsafe, raises: [].}
proc PyBuffer_FillInfo*(view: ptr Py_buffer, exporter: PyObjectPtr, buf: pointer, len: Py_ssize_t, readonly: cint, flags: cint): cint {.importc, cdecl, gcsafe, raises: [].}

# ---------------------------------------------------------------------------
# PyCapsule API
# ---------------------------------------------------------------------------
proc PyCapsule_New*(pointerVal: pointer, name: cstring, destructorFn: PyCapsule_Destructor): PyObjectPtr {.importc, cdecl, gcsafe, raises: [].}
proc PyCapsule_GetPointer*(capsule: PyObjectPtr, name: cstring): pointer {.importc, cdecl, gcsafe, raises: [].}
proc PyCapsule_IsValid*(capsule: PyObjectPtr, name: cstring): cint {.importc, cdecl, gcsafe, raises: [].}
