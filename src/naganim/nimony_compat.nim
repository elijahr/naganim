## Nimony 3.0 & Nim 2.x Compatibility Layer for naganim.
##
## Ensures all core naganim modules compile cleanly under both Nim 2.x (ORC/ARC)
## and Nimony 3.0's stricter type, pragma, and effect system.

when defined(nimony):
  const naganimNimony* = true
else:
  const naganimNimony* = false

template naganimGcSafe*(body: untyped): untyped =
  {.cast(gcsafe).}:
    body

template naganimNoSideEffect*(body: untyped): untyped =
  {.cast(noSideEffect).}:
    body
