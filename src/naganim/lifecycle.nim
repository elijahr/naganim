## naganim Runtime Lifecycle, Idempotent NimMain Guard & Exception Firewalls.
##
## Implements:
## - Atomic once-only `NimMain()` initialization (`CRIT-02`)
## - Thread-local C-ABI error state (`naganim_last_error`, `naganim_clear_error`)
## - Exception boundary firewalls (`cAbiBoundary`, `pyAbiBoundary`) catching both
##   `CatchableError` and `Defect` (`LOW-01`)

import std/atomics
import ./abi

type
  NaganimError* = object of CatchableError
  NaganimConversionError* = object of NaganimError
  NaganimPythonError* = object of NaganimError
  BufferExportedDefect* = object of Defect

proc NimMain() {.importc: "NimMain", cdecl, gcsafe, raises: [].}

var gNimMainInitialized*: Atomic[bool]
var gRuntimeRefCount*: Atomic[int]

# When NimMain() executes (either at standalone binary startup or on first
# naganim_init_runtime() call in a shared library), mark gNimMainInitialized = true.
gNimMainInitialized.store(true, moRelease)

var gThreadLastError {.threadvar.}: string
var gThreadHasError {.threadvar.}: bool

proc setLastError*(msg: string) {.gcsafe, raises: [].} =
  gThreadLastError = msg
  gThreadHasError = true

proc getLastError*(): string {.gcsafe, raises: [].} =
  if gThreadHasError:
    result = gThreadLastError
  else:
    result = ""

proc hasLastError*(): bool {.inline, gcsafe, raises: [].} =
  gThreadHasError

proc naganim_clear_error*() {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  gThreadLastError = ""
  gThreadHasError = false

proc naganim_last_error*(): cstring {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  if not gThreadHasError or gThreadLastError.len == 0:
    return nil
  return cstring(gThreadLastError)

proc naganim_set_last_error*(msg: cstring) {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  if msg.isNil:
    naganim_clear_error()
  else:
    gThreadLastError = $msg
    gThreadHasError = true

var gDeferredFlushHook*: proc() {.cdecl, gcsafe, raises: [].} = nil

proc naganim_init_runtime*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  ## Idempotent initialization of the Nim ORC runtime and naganim bridge.
  ## Returns 0 on success, -1 on error.
  if not gNimMainInitialized.exchange(true, moAcquireRelease):
    NimMain()
  discard gRuntimeRefCount.fetchAdd(1, moAcquireRelease)
  if not gDeferredFlushHook.isNil:
    gDeferredFlushHook()
  return 0

proc naganim_shutdown_runtime*(): cint {.exportc, cdecl, dynlib, gcsafe, raises: [].} =
  ## Flushes any pending deferred Python reference decrements when the caller
  ## holds a valid Python thread state, and decrements the runtime refcount.
  if not gDeferredFlushHook.isNil:
    gDeferredFlushHook()
  let prev = gRuntimeRefCount.fetchSub(1, moAcquireRelease)
  if prev <= 0:
    gRuntimeRefCount.store(0, moRelease)
  return 0

proc fetchPythonErrorMessage*(): string {.gcsafe, raises: [].} =
  ## Fetches and clears the active Python exception on the current thread,
  ## formatting its type and value into a Nim string.
  if Py_IsInitialized() == 0 or PyGILState_Check() == 0:
    return "Python exception occurred (no active thread state)"
  if PyErr_Occurred().isNil:
    return "Unknown Python exception"
  var ptype, pvalue, ptraceback: PyObjectPtr
  PyErr_Fetch(addr ptype, addr pvalue, addr ptraceback)
  var msg = "PythonError"
  if not ptype.isNil:
    let typeStrObj = PyObject_Str(ptype)
    if not typeStrObj.isNil:
      var sz: Py_ssize_t = 0
      let cs = PyUnicode_AsUTF8AndSize(typeStrObj, addr sz)
      if not cs.isNil and sz > 0:
        msg = newString(int(sz))
        copyMem(addr msg[0], cs, int(sz))
      Py_DecRef(typeStrObj)
  if not pvalue.isNil:
    let valStrObj = PyObject_Str(pvalue)
    if not valStrObj.isNil:
      var sz: Py_ssize_t = 0
      let cs = PyUnicode_AsUTF8AndSize(valStrObj, addr sz)
      if not cs.isNil and sz > 0:
        var valStr = newString(int(sz))
        copyMem(addr valStr[0], cs, int(sz))
        msg.add(": " & valStr)
      Py_DecRef(valStrObj)
  if not ptype.isNil:
    Py_DecRef(ptype)
  if not pvalue.isNil:
    Py_DecRef(pvalue)
  if not ptraceback.isNil:
    Py_DecRef(ptraceback)
  return msg

template cAbiBoundary*(body: untyped): cint =
  ## Exception firewall for C-ABI (`cffi` / native C) entrypoints.
  ## Catches both `CatchableError` and `Defect` (`LOW-01`) so Nim exceptions
  ## never unwind across foreign C stack frames.
  block:
    discard naganim_init_runtime()
    naganim_clear_error()
    var statusCode: cint = 0
    try:
      body
    except CatchableError as e:
      setLastError($e.name & ": " & e.msg)
      statusCode = -1
    except Defect as d:
      setLastError($d.name & ": " & d.msg)
      statusCode = -2
    except Exception as ex:
      setLastError($ex.name & ": " & ex.msg)
      statusCode = -3
    statusCode

template pyAbiBoundary*(body: untyped): PyObjectPtr =
  ## Exception firewall for CPython `abi3` / `abi3t` `PyCFunction` entrypoints.
  ## Catches `CatchableError`, `Defect`, and root `Exception` (`LOW-01`), translates
  ## them into Python exceptions via `PyErr_SetString`, and returns `nil`.
  block:
    discard naganim_init_runtime()
    var pyRes: PyObjectPtr = nil
    try:
      pyRes = body
    except NaganimConversionError as e:
      setLastError($e.name & ": " & e.msg)
      if PyErr_Occurred().isNil:
        PyErr_SetString(PyExc_TypeError, e.msg.cstring)
      pyRes = nil
    except CatchableError as e:
      setLastError($e.name & ": " & e.msg)
      if PyErr_Occurred().isNil:
        PyErr_SetString(PyExc_RuntimeError, ($e.name & ": " & e.msg).cstring)
      pyRes = nil
    except BufferExportedDefect as d:
      setLastError($d.name & ": " & d.msg)
      if PyErr_Occurred().isNil:
        PyErr_SetString(PyExc_BufferError, d.msg.cstring)
      pyRes = nil
    except Defect as d:
      setLastError($d.name & ": " & d.msg)
      if PyErr_Occurred().isNil:
        PyErr_SetString(PyExc_RuntimeError, ($d.name & ": " & d.msg).cstring)
      pyRes = nil
    except Exception as ex:
      setLastError($ex.name & ": " & ex.msg)
      if PyErr_Occurred().isNil:
        PyErr_SetString(PyExc_RuntimeError, ($ex.name & ": " & ex.msg).cstring)
      pyRes = nil
    pyRes
