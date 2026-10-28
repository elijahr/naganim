## Nimony 3.0 & Nim 2.x Compatibility Layer for phyne.
##
## Ensures all core phyne modules compile cleanly under both Nim 2.x (ORC/ARC)
## and Nimony 3.0's stricter type, pragma, and effect system.

when defined(nimony):
  const phyneNimony* = true
else:
  const phyneNimony* = false

template phyneGcSafe*(body: untyped): untyped =
  {.cast(gcsafe).}:
    body

template phyneNoSideEffect*(body: untyped): untyped =
  {.cast(noSideEffect).}:
    body
