# Package

version       = "0.1.0"
author        = "Axiomantic"
description   = "High-performance bidirectional Nim-Python bridge (CPython abi3/abi3t + CFFI + lockfree asyncio)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"

task testNim, "Run Nim unit and integration tests":
  exec "nim c -r tests/nim/test_phyne_all.nim"
  exec "rm -f tests/nim/test_phyne_all"

task testPython, "Run Python pytest suite (abi3/abi3t + CFFI + asyncio)":
  exec "uv run --with pytest --with pytest-asyncio --with cffi pytest -o addopts='' -v tests/python"
  exec "rm -rf .pytest_cache python/phyne/__pycache__ tests/python/__pycache__"

task test, "Run full Nim and Python test suites":
  exec "nim c -r tests/nim/test_phyne_all.nim"
  exec "rm -f tests/nim/test_phyne_all"
  exec "uv run --with pytest --with pytest-asyncio --with cffi pytest -o addopts='' -v tests/python"
  exec "rm -rf .pytest_cache python/phyne/__pycache__ tests/python/__pycache__"
