## Bidirectional Type Conversion & Marshaling Engine (`toPy` / `fromPy`).
##
## Implements `design.md` §3.4:
## - Primitives: `bool`, `int`/`int8`/`int16`/`int32`/`int64`, `uint`/`uint8`/`uint16`/`uint32`/`uint64`, `float`/`float32`/`float64`
## - Strings & Bytes: `string` (UTF-8 `str`), `seq[byte]` (`bytes`)
## - Containers: `seq[T]` (`list`), `Table[K, V]` (`dict`), `Option[T]` (`None` | `T`), `tuple` (`tuple`)
## - Opaque handles: `PyObj`, `PyObjectPtr`

import std/[atomics, options, tables, typetraits]
import ./abi
import ./lifecycle
import ./gc_bridge

var
  gPyTrueSingleton: Atomic[pointer]
  gPyFalseSingleton: Atomic[pointer]

proc classifyPyBool(obj: PyObjectPtr): int {.inline, gcsafe, raises: [].} =
  ## Returns 1 if `obj` is `Py_True`, 0 if `obj` is `Py_False`, or -1 otherwise.
  ## Caches the immortal singleton pointers so repeated calls perform zero C-API refcount traffic.
  var t = cast[PyObjectPtr](gPyTrueSingleton.load(moAcquire))
  var f = cast[PyObjectPtr](gPyFalseSingleton.load(moAcquire))
  if unlikely(t.isNil or f.isNil):
    let newT = PyBool_FromLong(1)
    let newF = PyBool_FromLong(0)
    if not newT.isNil:
      gPyTrueSingleton.store(cast[pointer](newT), moRelease)
      Py_DecRef(newT)
      t = newT
    if not newF.isNil:
      gPyFalseSingleton.store(cast[pointer](newF), moRelease)
      Py_DecRef(newF)
      f = newF
  if obj == t:
    return 1
  if obj == f:
    return 0
  return -1

# ---------------------------------------------------------------------------
# Forward declarations for recursive container marshaling
# ---------------------------------------------------------------------------
proc toPyRaw*(val: bool): PyObjectPtr {.gcsafe.}
proc toPyRaw*[T: SomeSignedInt](val: T): PyObjectPtr {.gcsafe.}
proc toPyRaw*[T: SomeUnsignedInt](val: T): PyObjectPtr {.gcsafe.}
proc toPyRaw*[T: SomeFloat](val: T): PyObjectPtr {.gcsafe.}
proc toPyRaw*(val: string): PyObjectPtr {.gcsafe.}
proc toPyRaw*(val: cstring): PyObjectPtr {.gcsafe.}
proc toPyRaw*(val: seq[byte]): PyObjectPtr {.gcsafe.}
proc toPyRaw*(val: PyObj): PyObjectPtr {.gcsafe.}
proc toPyRaw*(val: PyObjectPtr): PyObjectPtr {.gcsafe.}
proc toPyRaw*[T](val: Option[T]): PyObjectPtr {.gcsafe.}
proc toPyRaw*[T](val: seq[T]): PyObjectPtr {.gcsafe.}
proc toPyRaw*[K, V](val: Table[K, V]): PyObjectPtr {.gcsafe.}
proc toPyRaw*[T: tuple](val: T): PyObjectPtr {.gcsafe.}

proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[bool]): bool {.gcsafe.}
proc fromPyRaw*[T: SomeSignedInt](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.}
proc fromPyRaw*[T: SomeUnsignedInt](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.}
proc fromPyRaw*[T: SomeFloat](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.}
proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[string]): string {.gcsafe.}
proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[seq[byte]]): seq[byte] {.gcsafe.}
proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[PyObj]): PyObj {.gcsafe.}
proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[PyObjectPtr]): PyObjectPtr {.gcsafe.}
proc fromPyRaw*[T](obj: PyObjectPtr, _: typedesc[Option[T]]): Option[T] {.gcsafe.}
proc fromPyRaw*[T](obj: PyObjectPtr, _: typedesc[seq[T]]): seq[T] {.gcsafe.}
proc fromPyRaw*[K, V](obj: PyObjectPtr, _: typedesc[Table[K, V]]): Table[K, V] {.gcsafe.}
proc fromPyRaw*[T: tuple](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.}

# ---------------------------------------------------------------------------
# Implementations: Nim -> Python (toPyRaw returns a NEW reference)
# ---------------------------------------------------------------------------
proc toPyRaw*(val: bool): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  result = PyBool_FromLong(if val: 1 else: 0)
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*[T: SomeSignedInt](val: T): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  result = PyLong_FromLongLong(clonglong(val))
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*[T: SomeUnsignedInt](val: T): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  result = PyLong_FromUnsignedLongLong(culonglong(val))
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*[T: SomeFloat](val: T): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  result = PyFloat_FromDouble(cdouble(val))
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*(val: string): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  if val.len == 0:
    result = PyUnicode_FromStringAndSize("", 0)
  else:
    result = PyUnicode_FromStringAndSize(cstring(val), Py_ssize_t(val.len))
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*(val: cstring): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  if val.isNil:
    return pyNewNone()
  result = PyUnicode_FromStringAndSize(val, Py_ssize_t(val.len))
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*(val: seq[byte]): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  if val.len == 0:
    var empty: byte = 0
    result = PyBytes_FromStringAndSize(addr empty, 0)
  else:
    result = PyBytes_FromStringAndSize(unsafeAddr val[0], Py_ssize_t(val.len))
  if result.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())

proc toPyRaw*(val: PyObj): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  if val.raw.isNil:
    return pyNewNone()
  Py_IncRef(val.raw)
  return val.raw

proc toPyRaw*(val: PyObjectPtr): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  if val.isNil:
    return pyNewNone()
  Py_IncRef(val)
  return val

proc toPyRaw*[T](val: Option[T]): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  if val.isSome:
    return toPyRaw(val.get())
  else:
    return pyNewNone()

proc toPyRaw*[T](val: seq[T]): PyObjectPtr {.gcsafe.} =
  when T is byte:
    return toPyRaw(cast[seq[byte]](val))
  else:
    discard flushDeferredDecRefs()
    let listObj = PyList_New(Py_ssize_t(val.len))
    if listObj.isNil:
      raise newException(PhyneConversionError, fetchPythonErrorMessage())
    for i in 0 ..< val.len:
      var elemObj: PyObjectPtr = nil
      try:
        elemObj = toPyRaw(val[i])
      except CatchableError as e:
        Py_DecRef(listObj)
        raise e
      # PyList_SetItem steals the reference to elemObj
      if PyList_SetItem(listObj, Py_ssize_t(i), elemObj) != 0:
        Py_DecRef(listObj)
        raise newException(PhyneConversionError, fetchPythonErrorMessage())
    return listObj

proc toPyRaw*[K, V](val: Table[K, V]): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  let dictObj = PyDict_New()
  if dictObj.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  for k, v in val.pairs:
    var kObj: PyObjectPtr = nil
    var vObj: PyObjectPtr = nil
    try:
      kObj = toPyRaw(k)
      vObj = toPyRaw(v)
    except CatchableError as e:
      if not kObj.isNil: Py_DecRef(kObj)
      if not vObj.isNil: Py_DecRef(vObj)
      Py_DecRef(dictObj)
      raise e
    # PyDict_SetItem does NOT steal references
    let rc = PyDict_SetItem(dictObj, kObj, vObj)
    Py_DecRef(kObj)
    Py_DecRef(vObj)
    if rc != 0:
      Py_DecRef(dictObj)
      raise newException(PhyneConversionError, fetchPythonErrorMessage())
  return dictObj

proc toPyRaw*[T: tuple](val: T): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  const arity = tupleLen(T)
  let tupObj = PyTuple_New(Py_ssize_t(arity))
  if tupObj.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  var idx = 0
  for fieldVal in fields(val):
    var itemObj: PyObjectPtr = nil
    try:
      itemObj = toPyRaw(fieldVal)
    except CatchableError as e:
      Py_DecRef(tupObj)
      raise e
    # PyTuple_SetItem steals the reference to itemObj
    if PyTuple_SetItem(tupObj, Py_ssize_t(idx), itemObj) != 0:
      Py_DecRef(tupObj)
      raise newException(PhyneConversionError, fetchPythonErrorMessage())
    inc idx
  return tupObj

# ---------------------------------------------------------------------------
# High-level toPy returning RAII PyObj
# ---------------------------------------------------------------------------
proc toPy*[T](val: T): PyObj {.gcsafe.} =
  initPyObj(toPyRaw(val), borrowed = false)

# ---------------------------------------------------------------------------
# Implementations: Python -> Nim (fromPyRaw borrows `obj`)
# ---------------------------------------------------------------------------
proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[bool]): bool {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to bool")
  let cls = classifyPyBool(obj)
  if cls == 1:
    return true
  elif cls == 0:
    return false
  else:
    raise newException(PhyneConversionError, "Expected Python bool, got non-bool object")

proc fromPyRaw*[T: SomeSignedInt](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to int")
  if classifyPyBool(obj) >= 0:
    raise newException(PhyneConversionError, "Expected Python int, got bool")
  let v = PyLong_AsLongLong(obj)
  if v == -1 and not PyErr_Occurred().isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  if v < clonglong(low(T)) or v > clonglong(high(T)):
    raise newException(PhyneConversionError, "Integer value out of range for target Nim type")
  return T(v)

proc fromPyRaw*[T: SomeUnsignedInt](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to uint")
  if classifyPyBool(obj) >= 0:
    raise newException(PhyneConversionError, "Expected Python uint, got bool")
  let v = PyLong_AsUnsignedLongLong(obj)
  if not PyErr_Occurred().isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  if v > culonglong(high(T)):
    raise newException(PhyneConversionError, "Unsigned integer value out of range for target Nim type")
  return T(v)

proc fromPyRaw*[T: SomeFloat](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to float")
  if classifyPyBool(obj) >= 0:
    raise newException(PhyneConversionError, "Expected Python float, got bool")
  let v = PyFloat_AsDouble(obj)
  if v == -1.0 and not PyErr_Occurred().isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  return T(v)

proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[string]): string {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to string")
  var size: Py_ssize_t = 0
  let utf8Ptr = PyUnicode_AsUTF8AndSize(obj, addr size)
  if utf8Ptr.isNil:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  if size == 0:
    return ""
  result = newString(int(size))
  copyMem(addr result[0], utf8Ptr, int(size))

proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[seq[byte]]): seq[byte] {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to seq[byte]")
  var bufPtr: pointer = nil
  var size: Py_ssize_t = 0
  if PyBytes_AsStringAndSize(obj, addr bufPtr, addr size) != 0:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  if size == 0 or bufPtr.isNil:
    return @[]
  result = newSeq[byte](int(size))
  copyMem(addr result[0], bufPtr, int(size))

proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[PyObj]): PyObj {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to PyObj")
  return initPyObj(obj, borrowed = true)

proc fromPyRaw*(obj: PyObjectPtr, T: typedesc[PyObjectPtr]): PyObjectPtr {.gcsafe.} =
  discard flushDeferredDecRefs()
  return obj

proc fromPyRaw*[T](obj: PyObjectPtr, _: typedesc[Option[T]]): Option[T] {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil or pyIsNone(obj):
    return none(T)
  return some(fromPyRaw(obj, T))

proc fromPyRaw*[T](obj: PyObjectPtr, _: typedesc[seq[T]]): seq[T] {.gcsafe.} =
  when T is byte:
    return fromPyRaw(obj, seq[byte])
  else:
    discard flushDeferredDecRefs()
    if obj.isNil:
      raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to seq")
    let n = PyList_Size(obj)
    if n < 0:
      raise newException(PhyneConversionError, fetchPythonErrorMessage())
    result = newSeqOfCap[T](int(n))
    for i in 0 ..< n:
      let item = PyList_GetItem(obj, i) # Borrowed reference
      if item.isNil:
        raise newException(PhyneConversionError, fetchPythonErrorMessage())
      result.add(fromPyRaw(item, T))

proc fromPyRaw*[K, V](obj: PyObjectPtr, _: typedesc[Table[K, V]]): Table[K, V] {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to Table")
  let n = PyDict_Size(obj)
  if n < 0:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  result = initTable[K, V]()
  var pos: Py_ssize_t = 0
  var kObj: PyObjectPtr = nil
  var vObj: PyObjectPtr = nil
  while PyDict_Next(obj, addr pos, addr kObj, addr vObj) != 0:
    let k = fromPyRaw(kObj, K)
    let v = fromPyRaw(vObj, V)
    result[k] = v

proc fromPyRaw*[T: tuple](obj: PyObjectPtr, _: typedesc[T]): T {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.isNil:
    raise newException(PhyneConversionError, "Cannot convert nil PyObjectPtr to tuple")
  const expectedLen = tupleLen(T)
  let actualLen = PyTuple_Size(obj)
  if actualLen < 0:
    raise newException(PhyneConversionError, fetchPythonErrorMessage())
  if actualLen != Py_ssize_t(expectedLen):
    raise newException(
      PhyneConversionError,
      "Tuple arity mismatch: expected " & $expectedLen & ", got " & $actualLen
    )
  var idx = 0
  for fieldVal in fields(result):
    let item = PyTuple_GetItem(obj, Py_ssize_t(idx)) # Borrowed reference
    if item.isNil:
      raise newException(PhyneConversionError, fetchPythonErrorMessage())
    fieldVal = fromPyRaw(item, typeof(fieldVal))
    inc idx

proc fromPy*[T](obj: PyObjectPtr, _: typedesc[T]): T {.inline, gcsafe.} =
  fromPyRaw(obj, T)

proc fromPy*[T](obj: PyObj, _: typedesc[T]): T {.inline, gcsafe.} =
  fromPyRaw(obj.raw, T)

# ---------------------------------------------------------------------------
# Bidirectional Python Object Interaction Helpers (Nim calling Python)
# ---------------------------------------------------------------------------
proc pyImport*(moduleName: string): PyObj {.gcsafe.} =
  discard flushDeferredDecRefs()
  let m = PyImport_ImportModule(moduleName.cstring)
  if m.isNil:
    raise newException(PhynePythonError, fetchPythonErrorMessage())
  return initPyObj(m, borrowed = false)

proc getAttr*(obj: PyObj, name: string): PyObj {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.raw.isNil:
    raise newException(PhynePythonError, "Cannot get attribute '" & name & "' on nil PyObj")
  let attr = PyObject_GetAttrString(obj.raw, name.cstring)
  if attr.isNil:
    raise newException(PhynePythonError, fetchPythonErrorMessage())
  return initPyObj(attr, borrowed = false)

proc setAttr*[T](obj: PyObj, name: string, val: T) {.gcsafe.} =
  discard flushDeferredDecRefs()
  if obj.raw.isNil:
    raise newException(PhynePythonError, "Cannot set attribute '" & name & "' on nil PyObj")
  let pyVal = toPyRaw(val)
  let rc = PyObject_SetAttrString(obj.raw, name.cstring, pyVal)
  Py_DecRef(pyVal)
  if rc != 0:
    raise newException(PhynePythonError, fetchPythonErrorMessage())

proc callPy*(callable: PyObj, args: varargs[PyObj, toPy]): PyObj {.gcsafe.} =
  discard flushDeferredDecRefs()
  if callable.raw.isNil:
    raise newException(PhynePythonError, "Cannot call nil PyObj")
  let tup = PyTuple_New(Py_ssize_t(args.len))
  if tup.isNil:
    raise newException(PhynePythonError, fetchPythonErrorMessage())
  for i in 0 ..< args.len:
    let item = args[i].raw
    if item.isNil:
      let noneVal = pyNewNone()
      discard PyTuple_SetItem(tup, Py_ssize_t(i), noneVal)
    else:
      Py_IncRef(item)
      discard PyTuple_SetItem(tup, Py_ssize_t(i), item)
  let res = PyObject_CallObject(callable.raw, tup)
  Py_DecRef(tup)
  if res.isNil:
    raise newException(PhynePythonError, fetchPythonErrorMessage())
  return initPyObj(res, borrowed = false)

proc `$`*(obj: PyObj): string {.gcsafe.} =
  if obj.raw.isNil:
    return "<PyObj nil>"
  discard flushDeferredDecRefs()
  let s = PyObject_Str(obj.raw)
  if s.isNil:
    PyErr_Clear()
    return "<PyObj error>"
  defer: Py_DecRef(s)
  return fromPyRaw(s, string)

proc `==`*(a, b: PyObj): bool {.gcsafe.} =
  if a.raw == b.raw:
    return true
  if a.raw.isNil or b.raw.isNil:
    return false
  let rc = PyObject_RichCompareBool(a.raw, b.raw, Py_EQ)
  if rc < 0:
    PyErr_Clear()
    return false
  return rc == 1
