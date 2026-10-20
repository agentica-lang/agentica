# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic
Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `System.os()` returns the operating system: `"linux"`, `"macos"`, `"windows"`,
  or the lowercase `uname` name on another system.

- `agentica test` runs on Windows: its run folder is made in the first of
  `TMPDIR`, `TMP` and `TEMP` that is a folder.

- `--schedulers N` and the variable `AGENTICA_SCHEDULERS` set the number of
  scheduler threads (1 to 1024; the flag wins over a valid variable; a bad
  value in either exits 2). This is the first step of the multicore VM: the VM
  still runs one scheduler, so the default is 1 and a larger number exits 2 with
  a message instead of running as 1 (`agentica test` too). The same step builds
  Boehm with thread support, makes the task states atomic (with PARKING and
  WOKEN, taken before a wait is registered), puts ready tasks in a global run
  queue and reads the scheduler clock without the event loop. With one
  scheduler the order of tasks does not change.

- With the test-only switch `AGENTICA_VM_TEST_MULTICORE=1`, `--schedulers N`
  runs N scheduler threads beside one I/O thread, with standard input and
  output, files, FIFOs, TCP and TLS; HTTP, `Process`, `Duplex` and `Test.run`
  fail with `RUNTIME-INTERNAL` there for now. Without the switch a count above
  1 still exits 2. `make test-multicore` and `make vm-tsan-run` run the
  programs and the TCP and TLS tests on four schedulers. A task that a
  scheduler wakes runs next on that scheduler (a runnext slot), and an idle
  scheduler spins for up to 10 µs before it sleeps, so tasks that wake each
  other do not pay a thread wake and a move to another core for each wake.

- Native Windows regressions for ordinary-file line decoding, lock-owner
  cancellation, unsafe path aliases, depth/read-only removal failures,
  preservation of existing rename targets and junction destinations, localhost
  UNC operations and a confined cross-volume rename fixture.

- `make tests KIND=fast|files|slow|all` runs a whole test group, with
  `KIND=files` for the destructive filesystem cases, `DOCKER=1` to run a group
  in the Ubuntu test container (`tools/ubuntu-test.Dockerfile`) and `WINE=1`
  for the Windows checks under Wine.
- Docker-backed local reproduction for filesystem removal regressions and
  native Actions-runner coverage using per-job scratch directories, sentinels
  and bounded cleanup.
- `make windows-docker-build` and `make windows-docker-check`: cross-build the
  Windows VM, then run its C tests and the Windows CI fast Python modules under
  Wine, without a Windows machine.
- The Windows CI job sends Ctrl+Break to a VM in its own process group (exit
  149, children stopped, file data written, a stuck stdout does not hold the
  exit) and checks standard output and standard error on a pseudo console,
  including a line longer than the buffer whose first write ends inside a
  character.

### Changed

- TLS system trust uses the platform's own store when `ca_file` is empty and
  `SSL_CERT_FILE` is not set: the Security framework's roots and Keychain
  trust settings on macOS (a root the admin or user adds is trusted), and
  Crypt32's ROOT store on Windows.
  Linux keeps its CA bundle search. Certificates the system distrusts (macOS
  Deny settings, the Windows Disallowed store) are rejected, also as an
  intermediate or the server's own certificate. The store is read once per
  process. Only the certificates are copied: platform rules beyond them
  (Apple's date-based distrust and CT policy, the constraints trustd puts on
  system anchors, Windows NotBefore and disallowed-filetime properties) are
  not applied. A nonempty `ca_file` still replaces system trust, and
  verification cannot be turned off. The TLS adapter and its tests
  now build on Windows too, and the Platforms CI links the vendored OpenSSL
  statically on macOS and Windows (no `msys-2.0.dll`); the TCP and TLS
  builtins on Windows come with the TCP port.

- The HTTP client is now `std/http` code on `TCP` and `TLS` sockets: an owner
  task per client keeps the per-origin pool and `max_connections`, and one
  task per connection runs the requests. `vm/http_client.c` is gone. The API
  and the answers do not change. The client's tasks are not counted by
  `Task.pending_count`, are not `Test.test` leftovers, and survive a crash of
  the task that made the client. A call whose task timed out still lets its
  request finish, and the connection is closed, not pooled; a call whose task
  was cancelled while it waited for a connection is never sent. A connection
  with bytes left after a response, or whose input has ended, is not kept. The
  client's work now spends the step budget of `--max-steps`. Differences:
  `docs/vm/10-io-http.md` §10.7.1.

- The HTTP server checks a request body as UTF-8 as its bytes arrive: bytes
  that can never be UTF-8 get a 400 at once, before a later chunked framing
  error (which got its own 400 or 413) or the end of input (which got no
  answer).

- On HTTPS, the HTTP server's wait for a request's first byte
  (`request_timeout_ms`, later `idle_timeout_ms`) covers the whole TLS
  handshake, and the request deadline starts at the first decrypted byte. The
  first raw byte of the handshake used to start the request deadline.

- A plain `TCP.accept` whose task is cancelled after a connection arrived
  closes that connection (the peer reads end of input) instead of leaving it
  for the next accept, as TLS accepts already did.

- **Breaking:** on Windows, `Process.spawn_channel` gives the child a pipe per
  direction (read 3, write 4, `AGENTICA_CHANNEL=3,4`), so `channel_close` ends
  the child's input. A child that used the duplex pipe on descriptor 3, or a VM
  older than this release, finds no channel.

- **Breaking:** `_` is a discard wherever a name is bound, including a `for`
  variable (`for _ in 0...3` with `_ = f()` in the body). Reading `_` was
  allowed before and is now `CHECK-UNKNOWN-NAME`, and `_: Type = x` is now
  `PARSE-UNEXPECTED-TOKEN`.
- `AGENTICA_VM_TRACE=io` no longer prints `kind=sleep` and `kind=lock` job
  lines for sleeps and deadline waits; `AGENTICA_VM_TRACE=sched` prints
  `timer_arm` and `timer_fire` for them.
- A blocking call whose deadline and whose result fall in the same pass of the
  event loop now takes whichever the loop saw first: if the timer ran first the
  call times out, where it used to return the result if it had arrived by the
  time the task ran. The outcome of a job is set once, by the first writer
  (the base of the multicore VM); with one scheduler the order of tasks does
  not change.
- Windows removal opens entries without backup intent, so enabled backup or
  restore privileges do not bypass ordinary delete ACL checks.
- Confined Wine tests have a 3 GiB temporary storage limit: a fresh prefix
  exceeds the previous 1 GiB limit. Other test groups keep their existing cap.
- Windows `File.stat` documents what it really reports: `mode` carries only the
  read-only attribute (438 or 292) and `user_id` and `group_id` are always 0, so
  neither is an owner or an ACL. `create_private` and `mkdir_private` document
  their Windows owner-and-DACL guarantee instead of a Unix mode.
- Windows file locks are checked natively: contention across processes, release
  when the holder process is killed, and release when the owning task or handle
  ends.
- Windows filesystem errors preserve cross-device, unsupported-operation,
  cancellation, timeout, again, fault and character-encoding errors instead of
  reporting a generic I/O error.
- `Path.remove` now works on Windows, using native paths and removing
  reparse-point entries without traversing them.
- `Path.rename` now works on Windows with native no-replace semantics: an
  existing destination is preserved.
- Windows stdin reads run in the I/O pool, keeping tasks and timers responsive.
  A pending read can occupy one worker until input arrives, but process exit
  does not wait for it.
- `File.try_lock` is available on Windows. Unlike Unix advisory locks, Windows
  locks also prevent reads and writes through other handles while held.
- Writing to standard output or standard error no longer blocks the whole
  program on Windows. A print waits in the same queue as on Linux and macOS
  while the other tasks keep running, with the same 64 KiB buffer per stream,
  `IO.flush`, `--flush-timeout`, and the order between the two streams when both
  are given the same pipe (`2>&1`). A pipe is written by libuv without waiting
  on the loop. A console and a file are written by the I/O pool, so a console
  that is paused (a selection, Ctrl+S) cannot stop the other tasks; text is
  converted to UTF-16 for the console. The normal end of the run waits for the
  output within the flush limit. After a stop signal, and for the last error
  messages, a pipe, a console or any other handle that may wait for its reader
  gets one shared wait of up to 200 ms, because Windows has no non-blocking
  write to try.

### Fixed

- On Windows, `.com` programs run through `Process.spawn` (only `.exe` did),
  as the documentation said. The VM adds no implicit search of the working
  directory, but a relative `PATH` entry such as `.` resolves against it.
  `.bat` and `.cmd` still do not run (that needs `cmd.exe`, an implicit shell),
  `PATHEXT` is not read, and a request for `x.cmd` or `x.bat` no longer finds a
  planted `x.cmd.exe`. A Windows name such as `C:foo.exe`, `x.exe:stream`,
  `tool.exe.` (trailing dot or space), `\\?\C:\x.exe` or a path ending in
  `.cmd` or `.bat` fails with `executable is unavailable`.
- On macOS, a socket as standard output no longer stalls every task: a write is
  checked with `poll` first and cut to what the socket takes.
- Relative source paths containing a colon no longer gain an absolute source
  root; Windows drive paths require a letter, colon and separator.
- The Windows Docker check explicitly requires BuildKit/buildx for the
  checksum-verified toolchain download and installs its Perl dependency.
- Repeated `File.try_lock` calls on the same Windows handle succeed, and only
  lock contention returns `ok(false)`; access failures remain errors.
- `Process.close` of a child that has already ended, before the VM noticed its
  exit, no longer fails with `RUNTIME-PROCESS-CLOSE` on Windows, where stopping
  an ended process reports "no such process". The process tests also run on
  Windows now.

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

[unreleased]: https://github.com/sonic182/agentica/compare/0.4.1-beta.1...HEAD
[0.4.1-beta.1]:
https://github.com/sonic182/agentica/compare/0.4.0...0.4.1-beta.1
[0.4.0]: https://github.com/sonic182/agentica/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/sonic182/agentica/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/sonic182/agentica/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
