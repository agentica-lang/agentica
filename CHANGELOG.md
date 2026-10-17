# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Native Windows files, environment, driver and compiler bootstrap.

- Type aliases, default parameter values, heredocs, case guards and nested patterns.
- Enumerable methods for lists and maps, plus `String.compare`.
- `Task.map` with bounded concurrency and per-item timeouts.
- VM profiling and a security reporting policy.

### Changed

- Faster compilation, program startup and test execution, with fewer allocations.
- Simplified compiler internals and shared VM operations for a future JIT.
- CI runs on GitHub-hosted Linux, macOS and Windows runners.
- Updated documentation and contributor guidelines.

### Fixed

- Windows and macOS VM builds and Linux CI toolchain compatibility.
- Native Windows file I/O, environment access and Unicode path handling.
- BDD runner selection in bootstrap and replacement front ends.

### Removed

- **Breaking:** logger `_meta` functions; use the level functions with optional fields instead.
- The legacy Racket compiler and its development tools.

## [0.4.0] - 2026-10-16

### Added

- One Linux binary with the compiler, VM and standard library included.
- CLI and test driver written in Agentica, plus `agentica run` for bytecode.
- Bootstrap builds without Racket and checks that the compiler reproduces itself.

### Changed

- **Breaking:** `agentica-vm` is replaced by `agentica run`; `AGENTICA_VM` is removed.
- **Breaking:** use `make` to build the single binary; the old build targets and separate executables are removed.

## [0.3.0] - 2026-10-15

### Added

- Module constants, named imports, immutable sets and struct updates.
- TOML, binary data and structured logging libraries.
- Task await timeouts and channel ownership.
- Private files and directories, file locks, safe removal and atomic renames.
- Environment and canonical path access, bit operations and nanosecond timing.
- Runtime and test stack traces, with better diagnostic suggestions.

### Changed

- Faster list operations; numeric lists use half the memory.
- More file metadata and portable source paths in bytecode.
- **Breaking:** imports use `import Alias from "path"`; source files must contain valid UTF-8.
- **Breaking:** declarations follow a fixed order; parser and checker nesting is limited to 1,000 levels.
- **Breaking:** bytecode formats 4 and 5 require recompiling older programs; new builtin type names are reserved and structs cannot have a function field named `with`.
- **Breaking:** the test driver runs in Agentica, with changes to infrastructure errors and temporary-directory cleanup.
- **Breaking:** child processes no longer inherit VM metrics variables.

### Fixed

- Generic enum type-checker crashes and misleading test-runner error reports.

## [0.2.0] - 2026-10-14

### Added

- Ruby-style operators, string interpolation, methods, closures, ranges and pipes.
- Loop controls, digit separators and documentation comments.
- Channels, task supervision, resource ownership and private child-process communication.
- Unit tests and BDD written in Agentica.
- TCP, TLS and HTTP support on the VM, plus streaming file reads.
- Bytecode compilation, tail calls, execution tracing and improved CLI help.
- Expanded standard library, documentation site and portable Linux releases.

### Changed

- **Breaking:** the C VM replaces the Racket evaluator; seeded random sequences change, and asynchronous I/O requires Linux.
- **Breaking:** HTTP and BDD move to standard-library modules with revised APIs.
- **Breaking:** task crashes are isolated; resources close when their owning task ends, and tests use a private communication channel.
- **Breaking:** imports omit `.agc`; declarations need blank lines, `##` denotes documentation and new builtin names are reserved.
- **Breaking:** string interpolation, splitting and value formatting change; missing or empty CA files are errors, and bare process commands use only `PATH`.
- Default builds use system OpenSSL and libgc; releases bundle them.
- Adopted Apache-2.0 with the LLVM exception.

### Fixed

- VM shutdown hangs and blocking file, output and process operations.
- Imported type names in output and diagnostics.

## [0.1.0] - 2026-10-04

First release of Agentica, a statically typed language designed for AI agents.

### Added

- Racket interpreter with a CLI for running, checking and inspecting programs.
- Typed collections, structs, functions, modules, JSON and Result error handling.
- Stable diagnostics, machine-readable output and execution budgets.
- Tasks, networking, processes, file operations and BDD testing.
- Examples, agent skills and automated releases.

### Changed

- Improved operator diagnostics and internal error reporting.
- `main` returns `Void`; maps preserve insertion order and support fallible lookups.

[unreleased]: https://github.com/sonic182/agentica/compare/0.4.0...HEAD
[0.4.0]: https://github.com/sonic182/agentica/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/sonic182/agentica/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/sonic182/agentica/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
