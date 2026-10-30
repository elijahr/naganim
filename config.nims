import std/[os, strutils]

--mm:orc
--threads:on
--define:useMalloc
--define:noSignalHandler
--path:"$projectDir/src"

for candidatePath in [
  "/Users/eek/Development/lockfree/src",
  "/Users/eek/Development/workspaces/lockfree/task-lockfree-cabi/lockfree/src",
  "/Users/eek/.nimble/pkgs2/typestates-0.14.0-579b80cedeafc9b92d8ee49b396990fec822a54b",
  "/Users/eek/.nimble/pkgs2/typestates-0.14.0-579b80cedeafc9b92d8ee49b396990fec822a54b/src",
  "/Users/eek/.nimble/pkgs2/unittest2-0.3.0-a14b3648dc8bbbaefd0b16d9567b567cc264b042"
]:
  if dirExists(candidatePath):
    switch("path", candidatePath)

when defined(macosx):
  when defined(naganimExtensionModule):
    switch("passL", "-Wl,-undefined,dynamic_lookup")
  else:
    let (ldFlags, exitCode) = gorgeEx("python3-config --ldflags --embed")
    if exitCode == 0:
      for flag in ldFlags.strip().splitWhitespace():
        if flag.len > 0:
          switch("passL", flag)
    else:
      switch("passL", "-Wl,-undefined,dynamic_lookup")
elif defined(linux):
  when not defined(naganimExtensionModule):
    let (ldFlags, exitCode) = gorgeEx("python3-config --ldflags --embed")
    if exitCode == 0:
      for flag in ldFlags.strip().splitWhitespace():
        if flag.len > 0:
          switch("passL", flag)
