# Agentica implementation roadmap

This roadmap turns the core specification in [`grammar.md`](../grammar.md) into
a usable interpreter. Planned syntax lives in
[`docs/future/`](../future/README.md) until its phase lands.

## Current implementation order

The core interpreter, Results, JSON primitives, function values, lightweight
tasks, BDD, TCP/TLS/HTTP, files/paths, strict Void, processes, modules and the
Ruby-style ergonomics are implemented. The bytecode VM is the only backend (7i
deleted the Racket evaluator, row 7.2): `agentica file.agc` compiles in-process
and runs on the VM of the same binary, and `agentica run` runs a compiled
`.agcb`. Small items stay open in 7e (loader validation for opcodes as they
land) and 7f (the extra corpora).

The table below is the one source for the order of pending work and its
dependencies; each row names its phases and the sections that specify them.
Historical phase numbers remain stable; this order governs pending work rather
than their numeric order.

The owner set the order of 2026-10-14 for the rows from 7.2.3 on. Rows 7.2.4 to
7.2.6 and 8 were the prerequisites of the bootstrap of the self-hosted front end
(§18), which started at row 7.2.7 (the freeze of the Racket front end). The
rows marked deferred waited until after the bootstrap. The VM-only and C-only
rows after them may run in parallel when needed and keep their relative order.

### Next, after 0.8.0 (owner, 2026-10-21)

The owner's order for the work after release 0.8.0. Two batches come first;
everything else is weighed after them.

- **Linux first:** new VM and C features land on Linux first. Until Windows
  and macOS support comes later, in separate work, the feature is refused
  there with a clear error, and its tests are skipped with a `known-issue: #N`
  reason that points to the port issue. The builds on all four systems keep
  passing.
- **Freeze:** after the FFI; see "Stable core" below.

First batch, as soon as possible:

1. FFI-a: the core of [#534](https://github.com/sonic182/agentica/issues/534)
   (extern blocks, `C.*` types, `resource`, the three call kinds,
   `Native.wait_readable/wait_writable`, `--allow-native`), with system or
   local libraries.
2. [#375](https://github.com/sonic182/agentica/issues/375): cache compiled
   bytecode, so unchanged programs skip the front end.
3. Packages [45b](../future/45-packages.md) (`fetch`), then 45c (`add`,
   `update`) and 45d (`vendor`); 45c and 45d need 45b.
4. FFI-b: native libraries in packages (`[native]` in `agentica.toml`, hashes
   in the lock); needs 45b.

Second batch, after the first:

5. The formatter
   [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt) (row 7.9).
   Its needs are the heredoc and the open questions of
   [§47.9](../future/47-formatter.md#479-open-questions), which the owner
   answers when the work starts.
6. [#396](https://github.com/sonic182/agentica/issues/396): smaller values,
   with compact storage instead of the 16-byte `agc_value`. It changes the
   value representation of the whole VM, so it must work on all four systems,
   not only Linux. It goes before the JIT.

Weighed later (no fixed order)

7. Regular expressions [§48](../future/48-regex.md#48-regular-expressions)
   (row 7.10).
8. The JIT (row 9.1, [§22](../future/22-jit.md)); it needs 8.1, 7.7 and 9, and
   comes after the FFI. #396 (item 6) goes before it.
9. [#531](https://github.com/sonic182/agentica/issues/531): `type-at` on type
   names (row 7.2b).
10. [#536](https://github.com/sonic182/agentica/issues/536): libFuzzer.
11. Flaky tests [#528](https://github.com/sonic182/agentica/issues/528) and
    [#382](https://github.com/sonic182/agentica/issues/382).
12. UDP [#450](https://github.com/sonic182/agentica/issues/450) (row 7.5): it
    leaves the core plan and may be a package built on the FFI later.
13. Strict diagnostics (row 7.6).
14. Test functions [§50](../future/50-test-functions.md#50-test-functions)
    (row 7.11).
15. `Set[T]` and `Queue[T]` (row 12).
16. HTTP streaming, 20e to 20g
    ([§30](../future/30-hybrid-http.md#3011-streaming-on-channels)), with
    `TlsContext` ([§29](../future/29-tls-context.md#29-tls-contexts)) and ALPN
    (19c).
17. [#469](https://github.com/sonic182/agentica/issues/469): the doc site.
18. `agentica help std/MODULE` (row 22b, part 2).
19. The Windows issues [#489](https://github.com/sonic182/agentica/issues/489),
    [#486](https://github.com/sonic182/agentica/issues/486),
    [#474](https://github.com/sonic182/agentica/issues/474),
    [#462](https://github.com/sonic182/agentica/issues/462),
    [#457](https://github.com/sonic182/agentica/issues/457),
    [#393](https://github.com/sonic182/agentica/issues/393) and
    [#385](https://github.com/sonic182/agentica/issues/385).
20. Signals [§46](../future/46-signals.md#46-signals) (row 7.8).

- **Order:** 1
  - **Next work:** **Complete:** Everyday library (5n plus strings,
    conversions, time and randomness)

- **Order:** 2
  - **Next work:** **Complete:** Typed JSON (5f2) and builders/schemas (5i)

- **Order:** 3
  - **Next work:** **Complete:** Modules and imports, including embedded `std/`
    and external `pkg/` resolution

- **Order:** 4
  - **Next work:** **Complete:** Ruby-style ergonomics (measured in evaluation
    rounds 5–8)

- **Order:** 5
  - **Next work:** **Mostly complete:** Bytecode VM core in C with the Boehm GC
    (`docs/vm/12-testing-and-pr-plan.md` §12.2 items 1 to 8), the 7g benchmark
    script, 7h part 1 (event loop and files) and ranges (8a); small items stay
    open in 7e (loader validation for opcodes as they land) and 7f

- **Order:** 6
  - **Next work:** **Complete:** 7h tasks with one scheduler (N=1), with the
    fairness rule of `docs/vm/10-io-scheduler.md` §10.2.1 (long builtins charge
    the turn, never `--max-steps`) and the latency test

- **Order:** 7
  - **Next work:** **Complete:** the VM is the default backend (7i, first
    item); the differential tests became golden tests; the release ships one
    `agentica` binary

- **Order:** 7.1
  - **Next work:** **Complete, catch-up:** 7h processes, VM tracing (14a), TCP,
    TLS, HTTP 20a (phase 20, `docs/vm/10-io-http.md` §10.7) and BDD in Agentica
    ([phase 21](21-bdd-in-agentica.md), [`docs/bdd.md`](../bdd.md)); each PR
    removed its fallback to the evaluator

- **Order:** 7.2
  - **Next work:** **Complete:** 7i: delete the evaluator and its runtime
    modules; the front end stayed. Decided by the owner on 2026-10-13: 7i came
    before HTTP 20b to 20d and deleted the builtin `HTTP` module with the
    evaluator, so `HTTP` is the free import alias of `std/http`; HTTP 20c then
    brought back a server (`std/http`, `examples/http_server.agc`)

- **Order:** 7.2.1
  - **Next work:** **Complete:** HTTP 20b (the task cancellation core), task
    crash isolation ([phase 24](24-task-crash-isolation.md)), unit tests
    ([phase 25](25-unit-tests.md), the grammar's
    [`Test` rules](../grammar/06c-tasks-and-tests.md#unit-tests-test)) and HTTP
    20c (the `std/http` server, which also took what was left of 20d;
    [§30](../future/30-hybrid-http.md#30-http-on-the-vm-simple-synchronous-hybrid));
    VM-only

- **Order:** 7.2.1c
  - **Next work:** **Done (2026-10-13):** VM architecture note
    ([§16](../vm/16-architecture.md#16-vm-architecture)), docs only.

- **Order:** 7.2.1b
  - **Next work:** **Done:** VM layers, first part of
    [7l](07-vm.md#7l-vm-layers) ([§15](../vm/15-layers.md#15-vm-layers)),
    VM-only, no behavior change. The rest of 7l stays at row 8.1.

- **Order:** 7.2.1d
  - **Next work:** **Done (2026-10-13):** asynchronous process close and an
    always-on file-flush limit (30 s default, `--flush-timeout MS`)
    ([§14.1](../vm/14-core-invariants.md#141-waiting),
    [§14.4](../vm/14-core-invariants.md#144-ending)).

- **Order:** 7.2.1e
  - **Next work:** **Done (2026-10-13):** `Channel[T]` (17b,
    [§27.2](../future/27-iteration-and-concurrency.md#272-channels)); 17a
    (`Task.map`) stayed at row 7.3.

- **Order:** 7.2.1g
  - **Next work:** **Done (2026-10-14):** pipe operator `\|>` (15l, in the
    [grammar's expression rules](../grammar/05-syntax.md#expressions-and-precedence));
    methods on structs and Lua-style metatables stay decided against
    ([§25.13](../future/25-ruby-typed-idioms.md#2513-decided-against-part-c)).

- **Order:** 7.2.1f
  - **Next work:** **Done (2026-10-13):** stdout and stderr on the loop,
    VM-only ([§10.2.2](../vm/10-io-scheduler.md#1022-the-loop)).

- **Order:** 7.2.1h
  - **Next work:** **Done (2026-10-14):** `File.each_line` (17d,
    [§27.4](../future/27-iteration-and-concurrency.md) step 1), VM-only
    builtin.

- **Order:** 7.2.1a
  - **Next work:** **Done:** core simplification, VM-only, held to the [VM core
    invariants](../vm/14-core-invariants.md#14-vm-core-invariants) (§14): the
    blocked-reads-at-exit fix (PRs #162 and #164), the child protocol on its
    own channel (25c) and the one handle-ownership rule (24b, §14.5: a handle
    belongs to the task that opened it, moves only explicitly with
    `Task.spawn_owning`).

- **Order:** 7.2.2
  - **Next work:** **Done (2026-10-14, `docs/eval.md` rounds 9 to 11):**
    evaluation pilot ([phase 6c](06-validation.md#phase-6c-agentica-against-typed-python)):
    a regression round of the `binary` arm plus a first 6c pilot; the full 6c
    round stays at step 10.

- **Order:** 7.2.3
  - **Next work:** **Done (2026-10-14, PRs #200, #201, #204, `docs/eval.md`
    round 12):** a smaller `agentica-programming` skill, more diagnostic hints,
    and a re-measure of the `skill` arm.

- **Order:** 7.2a
  - **Next work:** **Done:** doc comments (part 22a,
    [§32](../future/32-doc-comments.md#32-doc-comments): `##` lines, front end
    only) and digit separators ([phase 23](23-digit-separators.md), lexer
    only).

- **Order:** 8
  - **Next work:** **Done:** faster lists (8d): a persistent vector behind
    `List`, then unboxed `List[Int]` and `List[Float]` leaves. The review of
    what the VM inherited from Racket (7k) stays open, next to the 7g hot
    spots.

- **Order:** 7.2.4
  - **Next work:** **Done (PRs #220 and #223):** binary data (phase 13,
    [grammar](../grammar/05b-modules.md#binary-data-stdbinary)): the `Int` and
    `Float` bit builtins (13a) and `std/binary` (13b)
    ([phase 13](13-binary-data.md)).

- **Order:** 7.2.5
  - **Next work:** **Done (2026-10-14, PR #225):** stack traces on runtime
    errors (14b, `docs/vm/02-reference-behavior.md`), always on in the plain,
    `--ai` and `--json` formats ([phase 14](14-logging.md)).

- **Order:** 7.2.6
  - **Next work:** **Done (2026-10-14, PR #222):** the OS builtins the
    self-hosted front end needs, from
    [§18.4](../future/18-front-end-language.md#184-prerequisites):
    `System.env(name)` and `Path.real(path)`, C builtins under exception 1 of
    the std-first rule.

- **Order:** 7.2.7
  - **Next work:** **Done (2026-10-16; PRs #237–#311, then #313):** the Racket
    front-end freeze (owner, 2026-10-14: no new syntax or checker rules in
    `src/`, only bug fixes and catalog data) and the port to `compiler/` in
    [§18.3](../future/18-front-end-language.md#183-port). #313 deleted `src/`,
    froze `vm/unicode_data.c` as checked-in source, left
    `compiler/catalog/builtins_data.agc`, `check_tables.agc` and
    `unicode_table.agc` as hand-edited sources, and tagged `bootstrap-racket`.
    The freeze record stays in §18.

- **Order:** 7.2.8
  - **Next work:** **Done except 44e** (decided by the owner on 2026-10-15; it
    relaxed the freeze of row 7.2.7, like `Set[T]` (8b) and `value.with(...)`
    (15c), because `compiler/` needs it): the new import forms (44a0, a
    **Breaking:** change), module constants (44a2, bytecode format version 5
    with the Globals section, 44a1), and the table rewrites in `compiler/`
    (44b the lexer, 44c the parser and Unicode tables, 44d the linker and the
    builtin catalog). 44e (static data) only if start-up numbers ask for it.
    The rules are in the grammar ([imports](../grammar/05b-modules.md),
    [module constants](../grammar/06-semantics.md)).

- **Order:** 7.2.9
  - **Next work:** **Done (2026-10-16; PRs #261–#311):** the tests moved from
    rackunit to Python `unittest` (stdlib only), with the live comparisons
    frozen under `tests/fixtures/frontend/frozen/` (`tools/refreeze.py`);
    design: [§18.7](../future/18-front-end-language.md#187-tests).

- **Order:** 22b
  - **Next work:** **Part 1 done (2026-10-21):** `agentica doc PATH [--json]`.
    Part 2 pending: `agentica help std/MODULE`, front end only
    ([§32.6](../future/32-doc-comments.md)).
  - **Outcome:** Agents and people read a module's API with `agentica doc
    std/http`, in text or JSON

- **Order:** 7.2b
  - **Next work:** **Built (2026-10-21, issue #506):** the semantic CLI and
    `std/analysis` ([§39](../future/39-semantic-cli.md)),
    front end and CLI only, nothing to run. Open: `type-at` on type names
    (§39.3); the 6c round (row 10) measures the commands (§39.12)
  - **Outcome:** Agents list declarations, find definitions and references
    across modules, and get the checked type at a position, without reading
    whole files or guessing from `rg`

- **Order:** 7.5a
  - **Next work:** **Done (2026-10-16):** default parameter values (15a, in the
    [grammar's default parameters](../grammar/06-semantics.md#default-parameter-values)),
    in `compiler/`.

- **Order:** 7.6
  - **Next work:** **Pending** (each item changes the checker in `compiler/`).
    Strict diagnostics first (phase 16, `docs/future/26-strict-diagnostics.md`
    §26, no warnings: `CHECK-UNUSED-IMPORT`, `CHECK-UNUSED-VARIABLE`,
    `CHECK-UNREACHABLE-CODE`, `CHECK-UNUSED-RESULT`, in the order 16a, 16c, 16b,
    16d; front end only, each PR migrates the repo's programs); then Ruby typed
    idioms (phase 15, `docs/future/25-ruby-typed-idioms.md` §25, Part A, one
    way to do each thing): re-exports, value equality, lambdas, `File.open` with
    a block (15b, 15d, 15e, 15i; heredocs, 15j, and `with`, 15c, are built); one
    small PR each
  - **Outcome:** Unused imports, unused variables, unreachable code and ignored
    `Result` values are errors, and there are no warnings; agents write the Ruby
    forms they know, still checked, immutable and with one canonical form

- **Order:** 8.2
  - **Next work:** **Done (2026-10-16):** the prelude and the Enumerable
    methods (15f), in `compiler/`, `stdlib/prelude/` and the VM; `Lazy[T]`
    (17e, PRs #421 and #426). `format` (15k) is still deferred (row 7.6).

- **Order:** 8.3
  - **Next work:** **Done (2026-10-16, PR #326):** VM start-up cut, measured on
    the bootstrap build
    ([§18.5](../future/18-front-end-language.md#185-goals-and-targets)): the
    loader of the carried front end takes 8.3 ms, not 15. Numbers in
    [vm-benchmarks](../vm-benchmarks.md#speed-pass-vm-start-up-row-83).

- **Order:** 7.3
  - **Next work:** **Done:** iteration and concurrent collections (phase 17,
    `docs/future/27-iteration-and-concurrency.md` §27): `Task.map` (17a, PR
    #316), `Channel[T]` (17b, row 7.2.1e), `Task.await` with a timeout (17c),
    `File.each_line` (row 7.2.1h), `Lazy[T]` (17e, PRs #421 and #426).

- **Order:** 7.4
  - **Next work:** New features, VM-only (cont.): the streaming items of phase
    20 (20e to 20g,
    [§30](../future/30-hybrid-http.md#3011-streaming-on-channels), the hybrid
    HTTP plan), built on the channels of 17b; then `TlsContext`
    ([§29](../future/29-tls-context.md#29-tls-contexts)), then ALPN (19c, owner
    2026-10-16: the HTTP client stays small and opens its low layers,
    [§30.13](../future/30-hybrid-http.md))
  - **Outcome:** Programs stream HTTP bodies through channels, set up TLS with a
    `TlsContext`, and can write an HTTP/2 library on `TLS` with ALPN

- **Order:** 7.5
  - **Next work:** New features, VM-only (cont.): UDP (leaves the core plan,
    item 12 of the list after 0.8.0 above), then the `Crypto` module
    (`docs/future/20-crypto.md` §20: hashes, HMAC, constant-time compare,
    random bytes, password hashing and AEAD on OpenSSL 3; needs `Bytes`).
    Logging (14c, `std/logger`) is done.
  - **Outcome:** Programs send UDP, and sign, hash and encrypt

- **Order:** 7.7
  - **Next work:** VM metrics (phase 18, `docs/future/28-vm-metrics.md` §28:
    18a to 18d), VM-only, no language change; it needs only 7i (not the HTTP
    stack), and goes before the server measurement (7j). 18d
    ([§28.12](../future/28-vm-metrics.md#2812-memory-diagnosis-18d)) needs
    channels (17b) and, for handle bytes, the one-owner rule of 24b, both done.
  - **Outcome:** Prometheus scrapes a running VM; nothing costs anything while
    nobody asks

- **Order:** 7.8
  - **Next work:** **Weighed later** (the list after 0.8.0 above, item 20),
    decided by the owner on 2026-10-15 (design and plan:
    [§46](../future/46-signals.md#46-signals)):
    signals that a program can handle, in parts 46a subscription, 46b sending
    and 46d `std/http` drains its handlers on a stop (46c, the Racket driver,
    is obsolete, §46.7). 46d comes after 46b by the owner's order (§46.7 does
    not require it).
    46a and 46b may run earlier when no other VM PR is waiting.
  - **Outcome:** A container entrypoint can stop its children and exit on its
    own terms

- **Order:** 7.9
  - **Next work:** **Second batch** (the list after 0.8.0 above, item 5),
    decided by the owner on 2026-10-15 (design and plan:
    [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt)): a code
    formatter, `agentica fmt`, written in Agentica on the self-hosted lexer and
    parser (parts 47a to 47c; 47c adds `CHECK-LINE-TOO-LONG`, which replaces
    `tests/test_style_line_width.py`). 47d, the LSP format-document hook, is
    outside this order: it waits for the language server (§43, not scheduled).
  - **Outcome:** Every `.agc` file has one layout, checked in CI

- **Order:** 7.10
  - **Next work:** **Weighed later** (the list after 0.8.0 above, item 7),
    decided by the owner on 2026-10-15 (design and plan:
    [§48](../future/48-regex.md#48-regular-expressions)): regular expressions,
    std first: `std/regex` in Agentica (a parser and a linear-time Pike VM, no
    backtracking), then the regex literal `/pattern/flags` (48b, `compiler/`
    only); a C matcher only if measured (48c).
  - **Outcome:** A program searches, extracts, replaces and splits text with a
    pattern, and no pattern can stall the VM

- **Order:** 7.11
  - **Next work:** **Planned**, in the list after 0.8.0 above (item 14; design
    and plan: [§50](../future/50-test-functions.md#50-test-functions)): a
    `*_test.agc` file may have no `main`; its top-level `test_*` functions are
    its tests, and the front end adds the `main` that runs them (50a,
    `compiler/` only).
  - **Outcome:** A test file reads as a list of tests

- **Order:** 7.12
  - **Next work:** **49a and 49b implemented** (design:
    [§49](../future/49-type-aliases.md#49-type-aliases)): transparent aliases
    (`type Grid = List[List[Float]]`) and generic ones (`type Matrix[T] =
    List[List[T]]`) are compiler-only, with no bytecode or VM change.
    Post-bootstrap step 6.

- **Order:** 8.1
  - **Next work:** The rest of the VM layers (7l: opcode helpers, builtin
    metadata flags, the callback-builtin protocol; the header split is row
    7.2.1b); after the tasks PR, next to 7k

- **Order:** 9
  - **Next work:** Server measurement on the VM (7j), with the source → result
    runner (7g); it also reads the VM metrics of phase 18 (GC, run-queue delay,
    I/O) while the load runs
  - **Outcome:** Requests/s, p50/p99 latency (also while a CPU-bound task runs),
    peak memory and real start-up, against Python as an outside reference

- **Order:** 9.1
  - **Next work:** JIT (7m, `docs/future/22-jit.md` §22): required; its place
    and prerequisites are in the list after 0.8.0 above (item 8). JIT code must
    follow the multicore rules of row 11 (§16)
  - **Outcome:** Hot functions run as native code with the same results

- **Order:** 11
  - **Next work:** **Complete:** multicore schedulers (7h item): one I/O
    thread and N scheduler threads, HTTP (std/http), processes and `Test.run`
    included; N is one per logical core unless `--schedulers` sets it
    (`docs/vm/16-architecture.md` §16.9)

- **Order:** 10
  - **Next work:** Evaluation round: Agentica against typed Python on harder
    tasks (6c), the full round after the pilot of step 7.2.2, with the semantic
    CLI of row 7.2b (§39.12). The full round has no fixed order (owner,
    2026-10-21)
  - **Outcome:** Evidence on whether agents do better in Agentica than in typed
    Python

- **Order:** 12
  - **Next work:** Core data structures (phase 8): `Set[T]` and `Queue[T]` (may
    proceed in parallel with steps 6 to 11)
  - **Outcome:** Write loops and algorithms the Ruby way, without workarounds

- **Order:** 13
  - **Next work:** Real applications
  - **Outcome:** Validate the APIs with a file-processing CLI, automation script
    and HTTP service

- **Order:** 14
  - **Next work:** Cross-language benchmarks (phase 12): the same small programs
    in Agentica (VM), Ruby, Crystal and optionally Python. Round 1
    (single-threaded; needs the real applications, the 7g benchmark script,
    faster lists (8d) and the VM `IO` library, the last three done) goes before
    MCP; round 2 (concurrent programs) needs tasks on the VM (7h) and covers
    multicore (row 11)
  - **Outcome:** Honest speed numbers against Ruby and Crystal, and the VM hot
    spots to fix next

- **Order:** 15
  - **Next work:** MCP examples (5m), then Streamable HTTP
  - **Outcome:** Build protocol clients and servers on the proven foundations

- **Order:** 16
  - **Next work:** Adapters and JSON inspection (phase 10 goes before phase 9):
    call `Fn` fields without `.call`, `JSON.kind`, generic structs, JSON for
    enums, optional and nullable JSON fields
  - **Outcome:** Write adapters and read JSON of unknown shape without
    workarounds

- **Order:** 17
  - **Next work:** (On demand) Shared tables (phase 9): `Table[K, V]`; needs
    tasks on the VM (7h); starts when a real program needs it
  - **Outcome:** Share a cache or a counter that tasks update

- **Order:** 18
  - **Next work:** (On demand) Binary serialization (phase 11): typed
    `Term.encode`/`Term.decode` in CBOR; needs `Bytes`, generic structs (10c)
    and the JSON form of enums (10d); starts when a real program needs it
  - **Outcome:** Keep a disk cache or send values between Agentica processes
    without losing Int keys, Float bits or enums

- **Order:** 19
  - **Next work:** (On demand) SIMD in the VM (`docs/future/19-simd.md` §19):
    AVX2 first, with run-time dispatch and a scalar fallback; only after
    profiling (7j or phase 12) shows time in string, JSON or copy routines
  - **Outcome:** Faster string and JSON work without changing the release
    baseline

The self-hosted front end and a single binary
([§18](../future/18-front-end-language.md)), decided by the owner on
2026-10-13, are in the order from row 7.2.7 on, after their prerequisites (rows
8 and 7.2.4 to 7.2.6; [§18.6](../future/18-front-end-language.md#186-order)).
Its steps (§18.3) are PRs, not rows of this table.

The owner set this order for the work after the bootstrap on 2026-10-15 and
revised it on 2026-10-16, 2026-10-19 (multicore moved ahead of the JIT) and
2026-10-20 (packages before the FFI, issue
[#534](https://github.com/sonic182/agentica/issues/534)): the rows that waited
for the bootstrap come first, then the path to the JIT (row 9.1, which should
also speed up `agentica test`), and the other features after the JIT. The
package system and the FFI sit on that path. The list after 0.8.0 above
(2026-10-21) replaces that path. Multicore (row 11) and the native
Windows and macOS releases were done ahead of this order.

1. **Done (2026-10-16, PR #312)**: release 0.4.0, the first release with the
   single binary ([§18.3](../future/18-front-end-language.md#183-port)).
2. **Done (2026-10-16, PR #313)**: delete the Racket front end, freeze
   `vm/unicode_data.c` as checked-in source, tag `bootstrap-racket` (§18.2).
   Release 0.3.0 was the last with the Racket front end (owner decision,
   2026-10-15).
3. A speed pass on the self-hosted front end
   ([§18.5](../future/18-front-end-language.md#185-goals-and-targets)):
   **done (2026-10-16, PRs #315, #317, #319, #326)** for the `agentica test`
   start-up, the lexer, the interpreter loop and the loader, with shared small
   values ([§34](../future/34-shared-small-values.md)); numbers in
   [vm-benchmarks](../vm-benchmarks.md). Still to do: the parser, for room under
   100 ms for `stdlib/bdd/gherkin.agc`.
4. **Done (2026-10-16)**: default parameter values (row 7.5a), in `compiler/`.
5. **Done (2026-10-16, PRs #322 and #325):** `case` guards, nested patterns and
   the `<<~NAME` heredoc, in `compiler/` only (the two-step stage0 refresh of
   §18.2 is a later PR).
6. The other rows that waited for the bootstrap: the prelude (row 8.2),
   `agentica doc` (row 22b), the semantic CLI (row 7.2b, built 2026-10-21,
   issue #506), the 44b–44d table rewrites (**done 2026-10-16**), type aliases
   (row 7.12, §49: 49a and 49b done), and `Task.map` (**done**, 17a, PR #316).
   Strict diagnostics (row 7.6), test functions (row 7.11) and `help` part 2
   (row 22b) are in the list after 0.8.0 above.
7. The path to the JIT is replaced by the list after 0.8.0 above. The native
   Windows and macOS builds are done (release 0.5.0-beta.1). UDP leaves the
   core plan (below); see item 12.
8. The rest of the order is in the list after 0.8.0 above. Regex needs
   the owner's answer on the Ruby anchors question of
   [§48.10](../future/48-regex.md#4810-decisions-and-open-questions); the
   formatter needs the heredoc of step 5 and the open questions of
   [§47.9](../future/47-formatter.md#479-open-questions). Also later, in no
   fixed order: the 6c evaluation round (row 10) and the Unicode generator.

Stable core (owner decisions, 2026-10-20 and 2026-10-21). The C core stays
small, safe and stable: the language, the VM, the GC, the scheduler, tasks and
channels, JSON, and the OS primitives that need the event loop (files,
processes, timers, TCP and TLS). UDP is not in the core plan: it may be a
package built on the FFI later. Everything else is an extension: first a
package written in Agentica ([§45](../future/45-packages.md)), and a native
library through the FFI (issue
[#534](https://github.com/sonic182/agentica/issues/534)) only when it needs a
library in C, C++ or Rust. After the FFI lands, the core changes only for bugs,
platforms and speed (the JIT).

Designed, not scheduled, with no row in this table:

- Dates and times ([§41](../future/41-dates-and-times.md)). Its builtin types
  are checker changes, so they come after the Agentica front end (§41.13), as
  the owner decided on 2026-10-15. Its `Time.monotonic_ns` part is independent
  and has landed (§41.10).
- Sized numeric types ([§42](../future/42-sized-numeric-types.md)). Its types
  are checker changes, so they start after the bootstrap, in the Agentica front
  end (§42.14).

Idea, not scheduled, with no row: a language server
([§43](../future/43-language-server.md)). It would reuse the §39 commands and
the §32 doc comments, so it can only start after them (and is easiest on the
self-hosted front end of §18).

Designed, with no row: packages ([§45](../future/45-packages.md)). It is item 3
of the list after 0.8.0 above, before FFI-b (item 4). The owner answered §45.14
on 2026-10-20. Done: the TOML parser `std/toml` (45-0), the manifest, the lock
and `pkg/<name>/` imports from the cache (45a). Next: fetch and install
(45b).

After steps 1–2, target everyday scripts and automation. After steps 13 and 15
(real applications and MCP), target larger general-purpose programs. Keep
diagnostics, behavior tests, grammar, and the self-contained programming
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

This file holds what matters now: the order above and the general rules. Each
open or partly open part of the plan has its own file. Phase numbers stay as
they were, so "phase 13" is in `13-binary-data.md` and "7h" is in `07-vm.md`.

- [`06-validation.md`](06-validation.md): Phase 6, with 6c (Agentica against
  typed Python)
- [`07-vm.md`](07-vm.md): Phase 7, bytecode VM (7a to 7m; the design is in
  [`docs/vm/`](../vm/README.md))
- [`08-data-structures.md`](08-data-structures.md): Phase 8, core data
  structures
- [`12-benchmarks.md`](12-benchmarks.md): Phase 12, cross-language benchmarks
- [`13-binary-data.md`](13-binary-data.md): Phase 13, binary data
- [`14-logging.md`](14-logging.md): Phase 14, logging and debugging
- [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md): Phase 21, BDD in Agentica
  (`std/bdd`, a runner and a child VM per scenario; catch-up item 7h)
- [`23-digit-separators.md`](23-digit-separators.md): Phase 23, digit
  separators (`1_000`)
- [`24-task-crash-isolation.md`](24-task-crash-isolation.md): Phase 24, task
  crash isolation
- [`25-unit-tests.md`](25-unit-tests.md): Phase 25, unit tests (the `Test`
  module, `*_test.agc` in `agentica test`)
- [`pending-general-programming-and-mcp.md`](pending-general-programming-and-mcp.md):
  pending work: general programming and MCP
- [`ruby-style-ergonomics.md`](ruby-style-ergonomics.md): Ruby-style ergonomics
  (complete)
- [`later-extensions.md`](later-extensions.md): later extensions and open
  decisions
- [`01-foundations.md`](01-foundations.md): completed phases 1 to 5n, with the
  open 5d3 and 6a items

Planned syntax is in [`docs/future/`](../future/README.md).
