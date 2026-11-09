# naganim — Bidirectional Nim ↔ Python Bridge

[![Status: Experimental](https://img.shields.io/badge/status-experimental-orange.svg)](#status)

> [!WARNING]
> **Experimental / Pre-Alpha Software — Not Ready for Production**
> This project is an active research and development prototype. APIs, ABI layouts, and wire formats are unstable and subject to breaking changes without notice. Do not use in production systems.

`naganim` is a zero-compromise, high-performance bidirectional bridge between Nim (2.x & Nimony 3.0) and Python (CPython 3.11–3.15, Free-Threaded 3.13t–3.15t, and PyPy via CFFI), built on `elijahr/lockfree` and `headerkit`.
