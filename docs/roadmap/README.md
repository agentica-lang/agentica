# Agentica implementation roadmap

This roadmap turns the core specification in [`grammar.md`](../grammar.md) into
a usable interpreter. Planned syntax lives in
[`docs/future/`](../future/README.md) until its phase lands.

## Current implementation order

The core interpreter, Results, JSON, function values, tasks, BDD, TCP, TLS,
HTTP, files, processes, modules, packages and the FFI core are implemented. The
bytecode VM is the only backend: `agentica file.agc` compiles in-process and
runs on the VM of the same binary, and `agentica run` runs a compiled `.agcb`.
Small items stay open in 7e (loader validation for opcodes as they land) and 7f
(the extra corpora).

The list below is the one source for the order of pending work and its
dependencies; each item names its phases and the sections that specify them.
Phase and row numbers stay stable; done rows keep one line each, and git history
keeps their records.

### Order after 0.8.0 (owner, 2026-10-21)

Released: 0.9.0 (the FFI core, FFI-a, with its Windows and macOS parity) and
0.10.0 (the JIT groundwork, the rest of the FFI core, and the x86-64 JIT with
our own emitter, no sljit). The CHANGELOG has the records. The arm64 emitter
and smaller values (#396) are deferred.

- **Linux first:** new VM and C features land on Linux first. Until the Windows
  and macOS port, the feature is refused there with a clear error, and its
  tests are skipped with a `known-issue: #N` reason that points to the port
  issue. The builds on all four systems keep passing.
- **Freeze:** after the FFI; see "Stable core" below.

Items 1 to 4 (FFI-a, cached bytecode, packages
[§45](../future/45-packages.md), FFI-b) are done. Second batch:

5. The formatter
   [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt) (row 7.9).
   The owner answered the open questions of
   [§47.9](../future/47-formatter.md#479-open-questions) on 2026-10-31; 47a,
   47b and 47c are done, and 47d waits for the language server.
6. [#396](https://github.com/agentica-lang/agentica/issues/396): smaller values,
   with compact storage instead of the 16-byte `agc_value`. It changes the
   value representation of the whole VM, so it must work on all four systems,
   not only Linux.

Weighed later (no fixed order):

7. Regular expressions [§48](../future/48-regex.md#48-regular-expressions)
   (row 7.10).
8. The JIT (row 9.1, [§6.4](../vm/05-values-execution-builtins.md#64-jit)); it
   needs 8.1, 7.7 and 9, and comes after the FFI. What is left:
   [#756](https://github.com/agentica-lang/agentica/issues/756).
12. UDP [#450](https://github.com/agentica-lang/agentica/issues/450) (row 7.5):
    it leaves the core plan and may be a package built on the FFI later.
13. Strict diagnostics (row 7.6).
14. Test functions [§50](../future/50-test-functions.md#50-test-functions)
    (row 7.11).
15. `Set[T]` and `Queue[T]` (row 12; `Set` is done).
16. HTTP streaming, 20e to 20g
    ([§30](../future/30-hybrid-http.md#3011-streaming-on-channels)), with
    `TlsContext` ([§29](../future/29-tls-context.md#29-tls-contexts); 19a and
    ALPN, 19c, are done).
17. [#469](https://github.com/agentica-lang/agentica/issues/469): the doc site.
18. `agentica help std/MODULE` (row 22b, part 2).
19. The Windows issues
    [#474](https://github.com/agentica-lang/agentica/issues/474),
    [#462](https://github.com/agentica-lang/agentica/issues/462) and
    [#457](https://github.com/agentica-lang/agentica/issues/457).
20. Signals [§46](../future/46-signals.md#46-signals) (row 7.8).

### Done rows

- **1 to 4:** the everyday library (5n), typed JSON (5f2, 5i), modules with
  `std/` and `pkg/`, and the Ruby-style ergonomics (the accepted forms are in
  [§25](../future/25-ruby-typed-idioms.md)).
- **5 to 7:** the C VM core with the Boehm GC
  (`docs/vm/12-testing-and-pr-plan.md` §12.2), tasks with the fairness rule
  (`docs/vm/10-io-scheduler.md` §10.2.1), and the VM as the default backend.
- **7.1:** processes, VM tracing (14a), TCP, TLS, HTTP 20a and BDD in Agentica
  ([phase 21](21-bdd-in-agentica.md), [`docs/bdd.md`](../bdd.md)).
- **7.2:** `HTTP` is the free import alias of `std/http` (owner, 2026-10-13).
- **7.2.1:** HTTP 20b and 20c (`std/http`, its server), task crash isolation
  (phase 24: a crash ends only its task; a handle belongs to the task that
  opened it, [§14.5](../vm/14-core-invariants.md#145-handles)) and unit tests
  ([phase 25](25-unit-tests.md)).
- **7.2.1a to 7.2.1h:** the VM core
  ([§14](../vm/14-core-invariants.md#14-vm-core-invariants)), the first part of
  the [VM layers](07-vm.md#7l-vm-layers), the architecture note
  ([§16](../vm/16-architecture.md#16-vm-architecture)), asynchronous process
  close and the flush limit, `Channel[T]` (17b), stdout and stderr on the loop,
  the pipe operator `|>` (15l), and `File.each_line` (17d).
- **7.2.2, 7.2.3:** the 6c pilot and the smaller skill (`docs/eval.md`, rounds
  9 to 12).
- **7.2a:** doc comments (22a, [§32](../future/32-doc-comments.md)) and digit
  separators (phase 23, the grammar's literals).
- **7.2.4 to 7.2.6:** binary data (phase 13,
  [`std/binary`](../grammar/05b-modules.md#binary-data-stdbinary)), stack traces
  (14b), and `System.env` and `Path.real` for the self-hosted front end.
- **7.2.7 to 7.2.9:** the self-hosted front end
  ([§18](../future/18-front-end-language.md)), with the new import forms and
  module constants (44a0 to 44d; 44e, static data, only if start-up numbers
  ask), and the tests in Python.
- **7.2b:** the semantic CLI and `std/analysis`
  ([§39](../future/39-semantic-cli.md)); open: the §39.12 measurement (row 10).
- **7.3:** iteration and concurrency
  ([§27](../future/27-iteration-and-concurrency.md)): `Task.map`, channels,
  `Task.await` with a timeout, `File.each_line`, `Lazy[T]`.
- **7.5a:** default parameter values. **7.12:** type aliases (49a, 49b; the
  grammar).
- **8, 8.2, 8.3:** faster lists (8d), the prelude and the Enumerable methods
  (15f; `format`, 15k, is deferred to row 7.6), and the VM start-up cut
  ([vm-benchmarks](../vm-benchmarks.md#speed-pass-vm-start-up-row-83)).
- **11:** multicore schedulers (`docs/vm/16-architecture.md` §16.9).
- **17:** shared tables (phase 9): `ATS[K, V]`, the grammar's
  [Shared tables](../grammar/06c-tasks-and-tests.md#shared-tables-ats).
- **7.5, part:** logging (14c), `std/logger` on the std-only `LogRegistry`.

### Pending rows

- **Order:** 22b
  - **Next work:** part 2, `agentica help std/MODULE`, front end only
    ([§32.6](../future/32-doc-comments.md)).

- **Order:** 7.4
  - **Next work:** New features, VM-only: the streaming items of phase 20 (20e
    and 20f; 20g, the streamed server response, is built,
    [§30](../future/30-hybrid-http.md#3011-streaming-on-channels)),
    built on channels; `TlsContext` (19a) and ALPN (19c, owner 2026-10-16: the
    HTTP client stays small and opens its low layers,
    [§30.13](../future/30-hybrid-http.md)) are done
    ([§29](../future/29-tls-context.md#29-tls-contexts))
  - **Outcome:** Programs stream HTTP bodies through channels, set up TLS with a
    `TlsContext`, and can write an HTTP/2 library on `TLS` with ALPN

- **Order:** 7.5
  - **Next work:** UDP (leaves the core plan, item 12 above). The crypto
    module (`docs/future/20-crypto.md` §20) has landed
  - **Outcome:** Programs send UDP and encrypt

- **Order:** 7.6
  - **Next work:** Each item changes the checker in `compiler/`. Strict
    diagnostics first (phase 16, `docs/future/26-strict-diagnostics.md` §26, no
    warnings: `CHECK-UNUSED-IMPORT`, `CHECK-UNUSED-VARIABLE`,
    `CHECK-UNREACHABLE-CODE`, `CHECK-UNUSED-RESULT`, in the order 16a, 16c,
    16b, 16d; each PR migrates the repo's programs); then Ruby typed idioms
    (phase 15, `docs/future/25-ruby-typed-idioms.md` §25, Part A): value
    equality, lambdas, `File.open` with a block (15d, 15e, 15i; re-exports,
    15b, are done); one small PR each
  - **Outcome:** Unused imports, unused variables, unreachable code and ignored
    `Result` values are errors, and there are no warnings; agents write the Ruby
    forms they know, still checked, immutable and with one canonical form

- **Order:** 7.7
  - **Next work:** VM metrics (phase 18, `docs/future/28-vm-metrics.md` §28:
    18a to 18d), VM-only, no language change; before the server measurement
    (7j). 18d ([§28.12](../future/28-vm-metrics.md#2812-memory-diagnosis-18d))
    needs channels and the one-owner rule of 24b, both done.
  - **Outcome:** Prometheus scrapes a running VM; nothing costs anything while
    nobody asks

- **Order:** 7.8
  - **Next work:** Weighed later (item 20 above; design and plan:
    [§46](../future/46-signals.md#46-signals)): signals that a program can
    handle, in parts 46a subscription, 46b sending and 46d `std/http` drains
    its handlers on a stop (46c is obsolete, §46.7). 46d comes after 46b by the
    owner's order. 46a and 46b may run earlier when no other VM PR is waiting.
  - **Outcome:** A container entrypoint can stop its children and exit on its
    own terms

- **Order:** 7.9
  - **Next work:** Second batch (item 5 above; design and plan:
    [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt)):
    `agentica fmt`, written in Agentica on the self-hosted lexer and parser
    (parts 47a to 47c, done: the comment side list and its attachment, the
    printer with `fmt --check` and `make fmt-check`, then write mode, `fmt -`,
    `[style]` and `CHECK-LINE-TOO-LONG` with `make check-compiler`). 47d, the
    LSP hook, waits for the language server (§43, not scheduled).
  - **Outcome:** Every `.agc` file has one layout, checked in CI

- **Order:** 7.10
  - **Next work:** Weighed later (item 7 above; design and plan:
    [§48](../future/48-regex.md#48-regular-expressions)): `std/regex` in
    Agentica (a parser and a linear-time Pike VM, no backtracking), then the
    regex literal `/pattern/flags` (48b, `compiler/` only); a C matcher only if
    measured (48c). It needs the owner's answer on the Ruby anchors question of
    [§48.10](../future/48-regex.md#4810-decisions-and-open-questions).
  - **Outcome:** A program searches, extracts, replaces and splits text with a
    pattern, and no pattern can stall the VM

- **Order:** 7.11
  - **Next work:** Planned (item 14 above; design and plan:
    [§50](../future/50-test-functions.md#50-test-functions)): a `*_test.agc`
    file may have no `main`; its top-level `test_*` functions are its tests,
    and the front end adds the `main` that runs them (50a, `compiler/` only).
  - **Outcome:** A test file reads as a list of tests

- **Order:** 8.1
  - **Next work:** The rest of the VM layers (7l: opcode helpers, builtin
    metadata flags, the callback-builtin protocol), next to 7k

- **Order:** 9
  - **Next work:** Server measurement on the VM (7j), with the source → result
    runner (7g); it also reads the VM metrics of phase 18 while the load runs
  - **Outcome:** Requests/s, p50/p99 latency (also while a CPU-bound task runs),
    peak memory and real start-up, against Python as an outside reference

- **Order:** 9.1
  - **Next work:** JIT (7m, `docs/vm/05-values-execution-builtins.md`
    §6.4): required; its place
    and prerequisites are item 8 above. JIT code must follow the multicore
    rules of row 11 (§16)
  - **Outcome:** Hot functions run as native code with the same results

- **Order:** 10
  - **Next work:** The full 6c evaluation round, with the semantic CLI of row
    7.2b (§39.12). Round 13 (2026-10-22, `docs/eval.md`) ran it on 0.8.1: no
    query use, so it is inconclusive. No fixed order (owner, 2026-10-21)
  - **Outcome:** Evidence on whether agents do better in Agentica than in typed
    Python

- **Order:** 12
  - **Next work:** Core data structures (phase 8): `Queue[T]` (`Set[T]` is
    done)
  - **Outcome:** Write loops and algorithms the Ruby way, without workarounds

- **Order:** 13
  - **Next work:** Real applications
  - **Outcome:** Validate the APIs with a file-processing CLI, automation script
    and HTTP service

- **Order:** 14
  - **Next work:** Cross-language benchmarks (phase 12): the same small programs
    in Agentica (VM), Ruby, Crystal and optionally Python. Round 1
    (single-threaded) needs the real applications; round 2 (concurrent
    programs) covers multicore (row 11)
  - **Outcome:** Honest speed numbers against Ruby and Crystal, and the VM hot
    spots to fix next

- **Order:** 15
  - **Next work:** MCP examples (5m), then Streamable HTTP
  - **Outcome:** Build protocol clients and servers on the proven foundations

- **Order:** 16
  - **Next work:** Adapters and JSON inspection: call `Fn` fields without
    `.call`, `JSON.kind`, JSON for enums; generic structs (10c) and optional
    and nullable JSON fields (10e, `JsonField`) are done
  - **Outcome:** Write adapters and read JSON of unknown shape without
    workarounds

- **Order:** 18
  - **Next work:** (On demand) Binary serialization (phase 11): typed
    `Term.encode`/`Term.decode` in CBOR; needs the JSON form of enums (10d);
    starts when a real program needs it
  - **Outcome:** Keep a disk cache or send values between Agentica processes
    without losing Int keys, Float bits or enums

- **Order:** 19
  - **Next work:** (On demand) SIMD in the VM (`docs/future/19-simd.md` §19):
    AVX2 first, with run-time dispatch and a scalar fallback; only after
    profiling (7j or phase 12) shows time in string, JSON or copy routines
  - **Outcome:** Faster string and JSON work without changing the release
    baseline

Also open, in no fixed order: the parser speed pass of the self-hosted front end
([§18.5](../future/18-front-end-language.md#185-goals-and-targets), room under
100 ms for `stdlib/bdd/gherkin.agc`; numbers in
[vm-benchmarks](../vm-benchmarks.md)), the two-step stage0 refresh of §18.2,
and the Unicode generator (7k).

Stable core (owner decisions, 2026-10-20 and 2026-10-21). The C core stays
small, safe and stable: the language, the VM, the GC, the scheduler, tasks and
channels, JSON, and the OS primitives that need the event loop (files,
processes, timers, TCP and TLS). UDP is not in the core plan: it may be a
package built on the FFI later. Everything else is an extension: first a package
written in Agentica ([§45](../future/45-packages.md)), and a native library
through the FFI (issue
[#534](https://github.com/agentica-lang/agentica/issues/534)) only when it needs
a library in C, C++ or Rust. After the FFI lands, the core changes only for
bugs, platforms and speed (the JIT).

Designed, not scheduled, with no row in this table:

- Dates and times ([§41](../future/41-dates-and-times.md)). Its builtin types
  are checker changes in the Agentica front end (§41.13, owner 2026-10-15). Its
  `Time.monotonic_ns` part has landed (§41.10).
- Sized numeric types ([§42](../future/42-sized-numeric-types.md)), checker
  changes in the Agentica front end (§42.14).

Idea, not scheduled, with no row: a language server
([§43](../future/43-language-server.md)). It would reuse the §39 commands and
the §32 doc comments.

Keep diagnostics, behavior tests, grammar, and the self-contained programming
reference part of every phase. Specify new APIs in `docs/future/` before
implementation; move them into the grammar only when they land.

### Rules for the catch-up and new features

- Work is tested with golden outputs and independent Node/Python peers. New
  features are VM-only.
- Every language change goes into the Agentica front end (`compiler/`,
  [§18](../future/18-front-end-language.md)); a PR may relax a default rule
  when following it costs more than it saves, and says which rule and why.
- A PR that changes the VM core keeps the [VM core
  invariants](../vm/14-core-invariants.md#14-vm-core-invariants) (§14), or
  changes them first with the reason.

Historical phase sections retain their original completion signatures. The
current language uses Void for completion and Nil for data; grammar.md and the
programming reference contain the current signatures.

### New library features: `std/` first

- New library features that are pure computation over types that already exist
  start as `std/` modules written in Agentica (`stdlib/*.agc`, registered in
  `stdlib/MODULES`), not as builtins. Examples: numbers to bytes, bit tricks
  built on the `Int` builtins, text formatting, algorithms.
- A function moves to a C builtin later only when a measurement shows it is hot
  (`make bench`, the server measurement 7j, or phase 12). Its `std/` API does
  not change, results and error strings included, so user code does not change;
  only step counts may. The new builtin is public (no internal helper builtins,
  `docs/vm/03-ir-and-bytecode.md` §4.5). It goes in an existing builtin module
  whose first parameter type fits (for example
  `List.read_u32_be(data, offset)`), never under a module named like the `std/`
  module's documented import alias, so the import keeps working. It is
  documented like any other builtin, and the `std/` function becomes a one-line
  wrapper.
- Exceptions, which are builtins from day one, in C only:
  1. Anything that touches the OS: files, stdin and stdout, processes, sockets,
     TLS, time, signals, random bytes from the OS. A program cannot make system
     calls.
  2. Crypto: always through the TLS/crypto provider adapter (OpenSSL 3 today,
     `docs/future/20-crypto.md` §20), never hand-written in Agentica: a
     constant-time compare is impossible in an interpreter, and home-made crypto
     is a classic source of bugs.
  3. Parsers of untrusted input that have mature libraries: JSON on yyjson and
     HTTP on picohttpparser stay as decided.
  4. Anything that needs its own memory layout in the runtime: `Bytes`, and the
     insides of `Map` and `List`.
  5. Basic operations on the core types, at the level of operators, which would
     be loops or fragile code in Agentica: for example the `Int` bit operations
     and `Float` bit conversions of the grammar's
     [`std/binary`](../grammar/05b-modules.md#binary-data-stdbinary).
  6. Log registry state: the handler table and the global log level, which the
     VM runtime holds for `std/logger` (the grammar's logging section). It is
     runtime state, not computation. It is the first state the language
     keeps between calls, so it is limited to this registry and reached only
     through the `Logger` functions. Its two builtin types, the record
     `LogEvent` and the enum `LogLevel`, are builtins because handlers take
     them.
- Library code that must be generic over the builtin type variables, or that
  must be called as a method on a builtin type (`xs.find do ... end`), cannot be
  a `std/` module; it goes in the compiler prelude (`stdlib/prelude/*.agc`,
  see the development skill's `references/stages.md`), still written in
  Agentica. The prelude has guarded exceptions to "no internal helper builtins":
  `__fail_arg` and `__float_fixed`
  ([§25.11](../future/25-ruby-typed-idioms.md#2511-format)), which the loader
  accepts only in prelude functions. A concurrency helper that needs the
  scheduler is a C builtin instead (`Task.await` with a timeout, §27.3).
- Two builtin modules are std-only: `HttpWire` (phase 20,
  `docs/vm/10-io-http.md` §10.7), the framing layer under `std/http`, and
  `LogRegistry` (the grammar's logging section), the registry under
  `std/logger`. A public raw layer next to `std/http` would be a second way to
  do HTTP, and a public registry would let user code change the handlers without
  the `Logger` functions. So the linker lets only modules embedded from
  `stdlib/` call them (`std_only_name?` in `compiler/catalog/builtins.agc`),
  and user code gets `CHECK-UNKNOWN-NAME` with a help that names the std module
  to import.
- Not retroactive: existing builtins, JSON included, stay as they are.

## Files

This file holds the order above and the general rules. Each open or partly open
part of the plan has its own file; phase numbers stay as they were, so "7h" is
in `07-vm.md`. Done phases without open items have no file (git history keeps
them).

- [`01-foundations.md`](01-foundations.md): phases 1 to 5n, with the open 5d3
  and 6a items
- [`06-validation.md`](06-validation.md): Phase 6, with 6c (Agentica against
  typed Python)
- [`07-vm.md`](07-vm.md): Phase 7, bytecode VM (7a to 7m; the design is in
  [`docs/vm/`](../vm/README.md))
- [`08-data-structures.md`](08-data-structures.md): Phase 8, core data
  structures
- [`12-benchmarks.md`](12-benchmarks.md): Phase 12, cross-language benchmarks
- [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md): Phase 21, BDD in Agentica
  (later options)
- [`25-unit-tests.md`](25-unit-tests.md): Phase 25, unit tests (done; the
  record)
- [`pending-general-programming-and-mcp.md`](pending-general-programming-and-mcp.md):
  pending work: general programming and MCP
- [`later-extensions.md`](later-extensions.md): later extensions and open
  decisions

Planned syntax is in [`docs/future/`](../future/README.md).
