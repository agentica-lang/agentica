# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic
Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `extern` blocks and `Native.wait_*` work on macOS (x86_64 and arm64).
- `Native.string_at`, `Native.bytes_at` and `Native.pointer` read memory that C
  returns and make sentinel pointers.

### Fixed

- Windows: `install`, `add` and `update` no longer leave temporary git folders
  in the package cache.

## [0.9.0-beta.1] - 2026-10-22

### Added

- `extern` blocks call C functions of native libraries on Linux x86_64 and
  Windows x64; `--deny-native` refuses such a program.
- Native types `C.Int`, `C.Int64`, `C.Double`, `C.Bool`, `C.String`,
  `C.Pointer`, `C.Bytes`, and `resource Name, free: fn` freed once.
- `out` parameters of extern functions return a record with `result` and one
  field per out value.
- `compute def` runs a long native call on the compute pool while other tasks
  run.
- `Native.wait_readable` and `Native.wait_writable` park a task on a native
  descriptor (Linux only for now).
- `length` and `size` work on `Map`, `Set` and `Range`.
- Ruby synonyms `collect`, `select`, `inject`, `detect`, `member?` and `key?`.
- `List.first`, `List.last`, and `empty?` on `List`, `Map` and `String`.
- `--deny-run` (which also denies native calls), `--deny-net`, `--deny-fs`,
  `--deny-env` and `--sandbox`, also for `agentica test`.
- `agentica install` fetches the packages of `agentica.lock` into `deps/`;
  `add` and `update` edit `agentica.toml` and the lock. **Breaking:** scripts
  named `install`, `add` or `update` run as `agentica ./NAME`.
- Builds read packages only from `deps/<name>/`; `agc_libs/` stays for local
  libraries.
- Git dependencies take `subdir` (`agentica add ... --subdir DIR`), so one
  repository can hold several packages.
- Workspaces: a `[workspace]` table lets members of one repository use each
  other's folders directly.
- Compiled programs are cached in `_build/bytecode/` (`AGENTICA_BUILD_DIR`
  moves it); `--no-cache` turns it off.
- `agentica help NAME` maps Ruby, Python and JS names to the builtin, and
  unknown methods suggest the Ruby one.

### Changed

- `help` and diagnostics show the Ruby form of a builtin (`s.strip`); both
  names still work.
- Windows: `agentica.exe` is long-path aware, so paths of 260 characters or
  more work when `LongPathsEnabled` is set.

### Removed

- **Breaking:** `--allow-run` is gone: programs may start processes by
  default.

### Fixed

- On Windows, open TCP and TLS sockets are closed, not reset, at the end of a
  run.
- Windows: non-ASCII text typed on a console reaches standard input as UTF-8.

## [0.8.1] - 2026-10-22

### Added

- `agentica type-at` (and `std/analysis`) answers a type name in an annotation,
  a type argument, a field or a payload (`kind` `type`), with the struct, enum
  or alias as definition.
- `std/analysis` has `type_at_partial` and `refs_partial`, as `type-at` and
  `refs` with `--partial`.

## [0.8.0] - 2026-10-21

### Added

- `agentica symbol NAME [PATH...]` finds where a name is defined, with its
  signature, `##` doc and span.
- `agentica refs NAME|FILE:LINE:COL [PATH...]` lists every reference to a name
  or to the name at a position.
- `agentica type-at` gives the `doc` and `signature` of a definition, answers a
  builtin with its `help`, and answers a local (parameter, binding, `for`
  variable, `case` pattern name).
- `type-at` and `refs` take `--partial`: a program in which some functions do
  not check is still answered.
- `Std.source(path)` gives the text of a `std/` source that the binary carries.
- `std/analysis` answers `check`, `outline`, `type-at`, `symbol` and `refs` from
  a program, over a session with unsaved buffers.
- `Analysis.refresh(session, path)` keeps the checked program in the session,
  so the next questions skip parsing and checking when nothing changed.

### Changed

- `std/internal/` can be imported only from `std/` modules
  (`CHECK-IMPORT-IO`).
- `agentica check` no longer requires `main`, so a library file checks clean;
  `run` and `compile` still report a missing `main`.
- **Breaking:** `Std` is a reserved type name.

## [0.7.0] - 2026-10-21

### Added

- `agentica doc PATH [--json]` prints the exported API of a file or a `std/`
  module with its `##` docs.
- `agentica outline FILE [--json] [--stdin FILE]` lists the declarations of a
  file, private ones too, with their signatures, docs and spans.
- `agentica type-at FILE:LINE:COL [--json]` gives the type and the definition at
  a position of a checked file; `type-at --stdin FILE:LINE:COL` reads the file
  from standard input.

### Changed

- **Breaking:** programs run on one scheduler per logical core by default, so
  tasks run in parallel and their order is not fixed; use `--schedulers 1` (or
  `AGENTICA_SCHEDULERS=1`) for the old order. `--max-steps` can trip a little
  late with more than one scheduler. `agentica test` refuses `--schedulers`;
  the VMs it starts read `AGENTICA_SCHEDULERS`.
- `HTTP.wait` returns only after the server's handlers and the tasks they
  spawned have ended; it used to return as soon as the server was closed.

### Fixed

- `agentica check --stdin --json` is a usage error (exit 2); it used to take
  `--json` as the file name.
- A child's stderr no longer stalls the VM when the VM's stderr is not read,
  and it keeps its order with stdout when both go to one pipe (`2>&1`).
- A Unix socket as standard output no longer holds the end of the run when its
  reader reads only after the exit and the output fills more than a quarter of
  its buffer.

## [0.6.0] - 2026-10-21

### Added

- `agentica check --stdin FILE` checks standard input as if `FILE` held it.
- `JSON.kind(value)` gives the kind of a JSON value as a String.
- `agentica help --json` with no NAME prints every builtin as a JSON array.

### Changed

- **Breaking:** extra words after `agentica check FILE` are a usage error
  (exit 2); they used to be ignored.
- `agentica --json help` prints the JSON array, not the text summary.

## [0.5.0] - 2026-10-21

### Added

- Packages: git dependencies in `agentica.toml`, pinned by `agentica.lock`, and
  imports as `pkg/<name>/<module>` from a cache filled by hand (no fetching
  yet). New codes `PKG-*` and `CHECK-IMPORT-PACKAGE`.
- `String.to_bytes(s)`, the UTF-8 bytes of a String.
- `Crypto.sha256(data)`, the SHA-256 digest of a list of bytes.
- Generic type aliases: `type Matrix[T] = List[List[T]]`.
- `Lazy[T]` pipelines over lists, ranges, `Lazy.produce`, file lines
  (`File.foreach`) and channels (`ch.lazy`), with `try` in every step block
  and `lz.write_lines(path, timeout_ms)`.
- `Task.cancel(task)` cancels a task and its descendants.
- A line that starts with `.name` continues the line before it.
- `Profile.measure`, `Profile.steps()` and folded flame graph stacks.
- TLS sockets and `std/http` on Windows; Windows trust reads the CA store for
  intermediates.
- One CI conformance matrix on Linux, Windows and macOS (Intel and ARM).

### Changed

- **Breaking:** with an `agentica.toml` in the folder of the root file or above
  it (up to the file system root), `pkg/` searches `agc_libs/` beside that
  manifest, and the manifest must be valid (`PKG-MANIFEST-INVALID`).
- **Breaking:** `Lazy`, `Profile` and `Crypto` are reserved type names.
- The lingering close of `std/http` drops at most 256 KiB of input.

### Fixed

- A cancelled `TCP.accept` or socket read gives up its place at once, and a
  task spawned by a cancelled task starts cancelled.
- A type alias sees only its own parameters.
- Windows: `pkg/` roots follow the documented rules.
- Windows: a standard input read no longer holds a pool thread.
- Windows: a socket as standard output or error keeps its unread output at
  exit.

## [0.5.0-beta.1] - 2026-10-20

### Added

- Native release archives for Linux x86-64, Windows x86-64, macOS Intel and
  macOS Apple silicon, with `SHA256SUMS`.
- `TCP` on Windows and macOS, and `agentica test` on Windows.
- `System.os()`.
- `--schedulers N` (`AGENTICA_SCHEDULERS`): the first step of the multicore VM,
  which still runs one scheduler outside a test switch.
- Windows test tooling: `make tests KIND=...`, Docker and Wine checks, and
  native console and Ctrl+Break checks in CI.

### Changed

- **Breaking:** `_` is a discard wherever a name is bound; reading `_` is
  `CHECK-UNKNOWN-NAME`.
- **Breaking:** on Windows, `Process.spawn_channel` gives the child one pipe per
  direction (`AGENTICA_CHANNEL=3,4`).
- TLS system trust uses the macOS and Windows stores, read once per process on
  every system.
- The HTTP client is written in `std/http` over `TCP` and `TLS`, and shares one
  TLS context per client.
- HTTPS servers time the TLS handshake as part of the wait for a request.
- Windows: `Path.remove`, `Path.rename`, `File.try_lock` and non-blocking
  standard input and output.
- A deadline and a result in the same loop pass resolve in the order the loop
  saw them.

### Fixed

- Windows runs `.com` programs and refuses ambiguous executable names.
- A socket as standard output no longer stalls tasks on macOS.
- Early UTF-8 errors in HTTP request bodies, closing of a cancelled
  `TCP.accept`, and Windows file errors, locks and `Process.close`.

## [0.4.1-beta.1] - 2026-10-17

### Added

- Native Windows files, imports, environment, driver and compiler bootstrap.
- Native compiler bootstrap and copied-binary checks on Windows and macOS.

- Type aliases, default parameter values, heredocs, case guards and nested
  patterns.
- Enumerable methods for lists and maps, plus `String.compare`.
- `Task.map` with bounded concurrency and per-item timeouts.
- VM profiling and a security reporting policy.

### Changed

- Faster compilation, program startup and test execution, with fewer
  allocations.
- Simplified compiler internals and shared VM operations for a future JIT.
- CI runs on GitHub-hosted Linux, macOS and Windows runners.
- Updated documentation and contributor guidelines.

### Fixed

- Windows and macOS VM builds and Linux CI toolchain compatibility.
- macOS FIFO completion after a reader closes.
- Native Windows file I/O, environment access and Unicode path handling.
- BDD runner selection in bootstrap and replacement front ends.

### Removed

- **Breaking:** logger `_meta` functions; use the level functions with optional
  fields instead.
- The legacy Racket compiler and its development tools.

## [0.4.0] - 2026-10-16

### Added

- One Linux binary with the compiler, VM and standard library included.
- CLI and test driver written in Agentica, plus `agentica run` for bytecode.
- Bootstrap builds without Racket and checks that the compiler reproduces
  itself.

### Changed

- **Breaking:** `agentica-vm` is replaced by `agentica run`; `AGENTICA_VM` is
  removed.
- **Breaking:** use `make` to build the single binary; the old build targets and
  separate executables are removed.

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
- **Breaking:** imports use `import Alias from "path"`; source files must
  contain valid UTF-8.
- **Breaking:** declarations follow a fixed order; parser and checker nesting is
  limited to 1,000 levels.
- **Breaking:** bytecode formats 4 and 5 require recompiling older programs; new
  builtin type names are reserved and structs cannot have a function field named
  `with`.
- **Breaking:** the test driver runs in Agentica, with changes to infrastructure
  errors and temporary-directory cleanup.
- **Breaking:** child processes no longer inherit VM metrics variables.

### Fixed

- Generic enum type-checker crashes and misleading test-runner error reports.

## [0.2.0] - 2026-10-14

### Added

- Ruby-style operators, string interpolation, methods, closures, ranges and
  pipes.
- Loop controls, digit separators and documentation comments.
- Channels, task supervision, resource ownership and private child-process
  communication.
- Unit tests and BDD written in Agentica.
- TCP, TLS and HTTP support on the VM, plus streaming file reads.
- Bytecode compilation, tail calls, execution tracing and improved CLI help.
- Expanded standard library, documentation site and portable Linux releases.

### Changed

- **Breaking:** the C VM replaces the Racket evaluator; seeded random sequences
  change, and asynchronous I/O requires Linux.
- **Breaking:** HTTP and BDD move to standard-library modules with revised APIs.
- **Breaking:** task crashes are isolated; resources close when their owning
  task ends, and tests use a private communication channel.
- **Breaking:** imports omit `.agc`; declarations need blank lines, `##` denotes
  documentation and new builtin names are reserved.
- **Breaking:** string interpolation, splitting and value formatting change;
  missing or empty CA files are errors, and bare process commands use only
  `PATH`.
- Default builds use system OpenSSL and libgc; releases bundle them.
- Adopted Apache-2.0 with the LLVM exception.

### Fixed

- VM shutdown hangs and blocking file, output and process operations.
- Imported type names in output and diagnostics.

## [0.1.0] - 2026-10-04

First release of Agentica, a statically typed language designed for AI agents.

### Added

- Racket interpreter with a CLI for running, checking and inspecting programs.
- Typed collections, structs, functions, modules, JSON and Result error
  handling.
- Stable diagnostics, machine-readable output and execution budgets.
- Tasks, networking, processes, file operations and BDD testing.
- Examples, agent skills and automated releases.

### Changed

- Improved operator diagnostics and internal error reporting.
- `main` returns `Void`; maps preserve insertion order and support fallible
  lookups.

[unreleased]: https://github.com/sonic182/agentica/compare/0.9.0-beta.1...HEAD
[0.9.0-beta.1]: https://github.com/sonic182/agentica/compare/0.8.1...0.9.0-beta.1
[0.8.1]: https://github.com/sonic182/agentica/compare/0.8.0...0.8.1
[0.8.0]: https://github.com/sonic182/agentica/compare/0.7.0...0.8.0
[0.7.0]: https://github.com/sonic182/agentica/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/sonic182/agentica/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/sonic182/agentica/compare/0.5.0-beta.1...0.5.0
[0.5.0-beta.1]:
https://github.com/sonic182/agentica/compare/0.4.1-beta.1...0.5.0-beta.1
[0.4.1-beta.1]:
https://github.com/sonic182/agentica/compare/0.4.0...0.4.1-beta.1
[0.4.0]: https://github.com/sonic182/agentica/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/sonic182/agentica/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/sonic182/agentica/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
