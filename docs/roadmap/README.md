# Agentica implementation roadmap

This roadmap turns the core specification in [`grammar.md`](../grammar.md) into
a usable interpreter. Planned syntax lives in
[`docs/future/`](../future/README.md) until its phase lands. Keep every phase
focused on the core in sections 4–6 until the prototype can run and diagnose the
examples in sections 7–8. Enums were kept out of the initial milestone and are
now implemented as a later extension.

## Current implementation order

The core interpreter, Results, JSON primitives, function values, lightweight
tasks, BDD, TCP/TLS/HTTP, files/paths, strict Void, processes, modules and the
Ruby-style ergonomics are implemented. The bytecode VM is the default backend:
`agentica file.agc` compiles in-process and runs on the VM of the same binary
(since step 8d-2 the product is the single file `agentica`; `agentica run`
runs a compiled `.agcb`). The design (7b),
lowering, bytecode and the VM (`docs/vm/12-testing-and-pr-plan.md` §12.2 items 1
to 10), the 7g benchmark script, and 7h part 1 (event loop and files), tasks and
processes are done, with small items still open in 7e (loader validation for
opcodes as they land) and 7f (the extra corpora).
Ranges (8a) are done.

The VM is the only backend: 7i deleted the Racket evaluator (row 7.2). The table
below is the one source for the order of pending work and its dependencies; each
row names its phases and the sections that specify them. Historical phase
numbers remain stable; this order governs pending work rather than their numeric
order.

The owner set the order of 2026-10-14 for the rows from 7.2.3 on. Rows 7.2.4 to
7.2.6 and 8 are the prerequisites of the bootstrap of the self-hosted front end
(§18), which starts at row 7.2.7 (the freeze of the Racket front end). The rows
marked deferred wait until after the bootstrap. The VM-only and C-only rows
after them may run in parallel when needed and keep their relative order.

- **Order:** 1
  - **Next work:** **Complete:** Everyday library (remaining 5n plus strings,
    conversions, time and randomness)
  - **Outcome:** Write useful scripts without rebuilding basic helpers

- **Order:** 2
  - **Next work:** **Complete:** Typed JSON (5f2) and builders/schemas (5i)
  - **Outcome:** Handle structured input and construct replies

- **Order:** 3
  - **Next work:** **Complete:** Modules and imports, including embedded `std/`
    and external `pkg/` resolution
  - **Outcome:** Split larger programs across files

- **Order:** 4
  - **Next work:** **Complete:** Ruby-style ergonomics: operators, methods on
    builtins, interpolation, blocks and closures, `break`/`next`, printing any
    value with `to_s`, and the forms agents use (measured in evaluation rounds
    5–8)
  - **Outcome:** Accept the Ruby habits agents already have, with static types

- **Order:** 5
  - **Next work:** **Mostly complete:** Bytecode VM core in C with the Boehm GC
    (`docs/vm/12-testing-and-pr-plan.md` §12.2 items 1 to 8), the 7g benchmark
    script, 7h part 1 (event loop and files) and ranges (8a); small items stay
    open in 7c, 7e (loader validation for opcodes as they land) and 7f
  - **Outcome:** Checked programs run on the VM with the evaluator's exit code,
    stdout, program stderr and diagnostic codes, now recorded as golden outputs

- **Order:** 6
  - **Next work:** **Complete:** 7h tasks with one scheduler (N=1) on the
    structures split for N (`docs/vm/10-io-multicore.md` §10.2.3), with the
    fairness rule of §10.2.1 (long builtins charge the turn, never
    `--max-steps`) and the latency test of the 7h tasks item
  - **Outcome:** Concurrent programs on the VM; timers and I/O stay responsive
    while other tasks compute

- **Order:** 7
  - **Next work:** **Complete:** the VM is the default backend (7i, first item):
    `agentica file.agc` runs on the VM; programs that use `TCP`, `TLS`, `HTTP`
    or `BDD`, and `agentica test`, fell back to the evaluator at first (each 7.1
    PR removed its fallback, and 7i removed the last one, `HTTP`); the
    differential tests became golden tests; the release ships one `agentica`
    binary
  - **Outcome:** One backend for almost every program; CI runs each test once

- **Order:** 7.1
  - **Next work:** **Complete, catch-up:** 7h processes, then VM tracing (14a,
    `docs/vm/08-loader-and-cli.md` §9), then TCP, then TLS (today's API), then
    HTTP 20a (phase 20, `docs/vm/10-io-http.md` §10.7: hybrid and synchronous,
    whole messages, C for parsing, framing and the pool, `std/http` in Agentica,
    imported as `HTTP`), then BDD in Agentica ([phase
    21](21-bdd-in-agentica.md), 7h, [`docs/bdd.md`](../bdd.md): `std/bdd` and a
    runner in Agentica, a child VM per scenario); each PR removed its fallback
  - **Outcome:** Every example, CI smoke test and `agentica test` runs on the VM

- **Order:** 7.2
  - **Next work:** **Complete:** 7i: delete the evaluator and its runtime
    modules; the Racket front end (lexer, parser, checker, lowering, bytecode)
    stays. Decided by the owner on 2026-10-13: 7i came before HTTP 20b to 20d
    and deleted the builtin `HTTP` module with the evaluator (its last fallback
    user), so `HTTP` is the free import alias of `std/http` and programs keep
    its client; HTTP 20c then brought back a server (`std/http`,
    `examples/http_server.agc`)
  - **Outcome:** One backend

- **Order:** 7.2.1
  - **Next work:** **Complete:** HTTP 20b (the task cancellation core, done),
    then task crash isolation ([phase 24](24-task-crash-isolation.md),
    crash isolation (phase 24): a crash
    in a task other than `main` ends only that task; it needs 20b; done), then
    unit tests ([phase 25](25-unit-tests.md),
    the grammar's
    [`Test` rules](../grammar/06c-tasks-and-tests.md#unit-tests-test): the
    builtin `Test`
    module and `*_test.agc` files in `agentica test`; after phase 24, so a crash
    fails one test; done), then HTTP 20c (done: the `std/http` server, which
    brings back an HTTP server and `examples/http_server.agc`, and also takes
    what was left of 20d, since 7i did the switch; it does not depend on phases
    24 and 25 and could go before them;
    [§30](../future/30-hybrid-http.md#30-http-on-the-vm-simple-synchronous-hybrid)); VM-only.
    The owner set this order on 2026-10-13: 7i, then HTTP 20b, then [phase
    24](24-task-crash-isolation.md), then [phase 25](25-unit-tests.md), then
    20c, then doc comments (phase 22) and digit separators (phase 23); the 6c
    pilot (row 7.2.2, decided by the owner the same day) now comes between 20c
    and doc comments, after the VM layers of row 7.2.1b and the core
    simplification of row 7.2.1a
  - **Outcome:** Programs serve HTTP again, with handlers that return a whole
    response; a crash in a task ends only that task; `agentica test` runs unit
    tests next to the features

- **Order:** 7.2.1c
  - **Next work:** **Done (2026-10-13):** VM architecture note
    ([§16](../vm/16-architecture.md#16-vm-architecture)), docs only.
  - **Outcome:** One picture of the threads, the queues and who owns what

- **Order:** 7.2.1b
  - **Next work:** **Done:** VM layers, first part of
    [7l](07-vm.md#7l-vm-layers), VM-only, no behavior change
    ([§15](../vm/15-layers.md#15-vm-layers)): core/services/adapters with
    one-way dependencies, the port, and the `make vm-layers` CI check.
    The rest of 7l stays at row 8.1.
  - **Outcome:** The core never calls a service by name, and CI keeps it so

- **Order:** 7.2.1d
  - **Next work:** **Done (2026-10-13):** asynchronous process close and an
    always-on file-flush limit (30 s default, `--flush-timeout MS`)
    ([§14.1](../vm/14-core-invariants.md#141-waiting),
    [§14.4](../vm/14-core-invariants.md#144-ending)).
  - **Outcome:** `Process.close` never blocks the loop thread, and the end of a
    run is always bounded

- **Order:** 7.2.1e
  - **Next work:** **Done (2026-10-13):** `Channel[T]` (17b,
    [§27.2](../future/27-iteration-and-concurrency.md#272-channels)), spec
    then implementation; 17a (`Task.map`) stayed at row 7.3.
  - **Outcome:** Producer and consumer pipelines with one form, and a parking
    mechanism for bounded buffers

- **Order:** 7.2.1g
  - **Next work:** **Done (2026-10-14):** pipe operator `\|>` (15l, in the
    [grammar's expression rules][grammar-syntax-precedence]); methods on
    structs and Lua-style metatables stay decided against
    ([§25.13](../future/25-ruby-typed-idioms.md#2513-decided-against-part-c)).
  - **Outcome:** User functions chain left to right, with one form per call

- **Order:** 7.2.1f
  - **Next work:** **Done (2026-10-13):** stdout and stderr on the loop,
    VM-only: `puts`, `print`, `IO.inspect` and `IO.warn` park the task on
    the channel parking mechanism (row 7.2.1e); spec in
    [§10.2.2](../vm/10-io-scheduler.md#1022-the-loop).
  - **Outcome:** A full stdout pipe no longer stalls every task

- **Order:** 7.2.1h
  - **Next work:** **Done (2026-10-14):** `File.each_line` (17d,
    [§27.4][agentica-link-1] step 1), VM-only builtin.
  - **Outcome:** Big files are read line by line in bounded memory with one call

- **Order:** 7.2.1a
  - **Next work:** **Done:** core simplification, VM-only, held to the [VM core
    invariants](../vm/14-core-invariants.md#14-vm-core-invariants) (§14):
    the blocked-reads-at-exit fix (PRs #162 and #164), the child protocol on
    its own channel ([25c](25-unit-tests.md),
    [a task per test][agentica-link-2]), and the one handle-ownership rule
    ([24b](24-task-crash-isolation.md), [handle ownership][task-rules],
    §14.5: a handle belongs to the task that opened it, moves only
    explicitly with `Task.spawn_owning`).
  - **Outcome:** Tests read their own stdin and print freely; one rule for who
    closes a handle; a smaller core

- **Order:** 7.2.2
  - **Next work:** **Done (2026-10-14, `docs/eval.md` rounds 9 to 11):**
    evaluation pilot after rows 7.2.1–7.2.1a ([phase
    6c](06-validation.md#phase-6c-agentica-against-typed-python)): a
    regression round of the `binary` arm plus a first 6c pilot; results set
    the order of the rows that followed; the full 6c round stays at step 10.
  - **Outcome:** Evidence that the VM-only language did not regress for agents,
    and a first answer on Agentica against typed Python

- **Order:** 7.2.3
  - **Next work:** **Done (2026-10-14, PRs #200, #201, #204, `docs/eval.md`
    round 12):** a smaller `agentica-programming` skill, more diagnostic
    hints, and a re-measure of the `skill` arm.
  - **Outcome:** Agents spend fewer tokens to learn the language, the common
    errors come with a hint, and the re-measure shows whether agents fail less

- **Order:** 7.2a
  - **Next work:** **Done:** doc comments (part 22a,
    [§32](../future/32-doc-comments.md#32-doc-comments): `##` lines, front end
    only) and digit separators ([phase 23](23-digit-separators.md),
    `1_000`, lexer only).
  - **Outcome:** Programs carry `##` docs in their source, and write long
    numbers as `1_000_000`

- **Order:** 8
  - **Next work:** **Done:** faster lists (8d): a persistent vector behind
    `List`, then unboxed `List[Int]` and `List[Float]` leaves; then the
    review of what the VM inherited from Racket (7k), next to the 7g hot
    spots.
  - **Outcome:** `push` stops copying the whole list; list-heavy programs stop
    being O(n²)

- **Order:** 7.2.4
  - **Next work:** **Done (PRs #220 and #223):** binary data (phase 13,
    [grammar](../grammar/05b-modules.md#binary-data-stdbinary)): the `Int`
    and `Float` bit builtins (13a) and `std/binary` (13b), with tests and
    docs ([phase 13](13-binary-data.md)).
  - **Outcome:** Programs read and write binary numbers with `std/binary`

- **Order:** 7.2.5
  - **Next work:** **Done (2026-10-14, PR #225):** stack traces on runtime
    errors (14b, `docs/vm/02-reference-behavior.md`), always on in the
    plain, `--ai` and `--json` formats ([phase 14](14-logging.md)).
  - **Outcome:** Agents see the call stack of a runtime error, and a crash in
    the self-hosted compiler shows where it happened

- **Order:** 7.2.6
  - **Next work:** **Done (2026-10-14, PR #222):** the OS builtins the
    self-hosted front end needs, from
    [§18.4](../future/18-front-end-language.md#184-prerequisites):
    `System.env(name)` and `Path.real(path)` (module identity and the `pkg/`
    escape check), C builtins under exception 1 of the std-first rule.
  - **Outcome:** The linker of the self-hosted front end finds `std/` and `pkg/`
    modules and checks their real paths

- **Order:** 7.2.7
  - **Next work:** **Done (2026-10-16; PRs #237–#311, then #313):** the
    Racket front-end freeze (owner, 2026-10-14: no new syntax or checker
    rules in `src/`, only bug fixes and catalog data) and the port to
    `compiler/` in [§18.3](../future/18-front-end-language.md#183-port):
    steps 1–6 (lexer, parser, modules/linker, catalog/checker, lowering,
    writer), step 7 (BDD driver), step 8 (CLI, single binary, frozen
    goldens, test move, the 8d switch to `dist/agentica`). #313 deleted
    `src/`, froze `vm/unicode_data.c` as checked-in source, left
    `compiler/builtins_data.agc`, `check_tables.agc` and
    `unicode_table.agc` as hand-edited sources, and tagged
    `bootstrap-racket`. History in git; the freeze record stays in §18.
  - **Outcome:** The front end is written once, in Agentica; every language
    change goes into `compiler/`

- **Order:** 7.2.8
  - **Next work:** **Started (2026-10-15, 44a0-1 PR #262, 44a0-2 PR #268, 44a2
    PRs #270 and #271), decided
    by the owner on 2026-10-15; it relaxes the freeze of row 7.2.7**, like
    `Set[T]` (8b) and `value.with(...)` (15c), because `compiler/` needs it. Two
    parts. **Imports (44a0, lands first):** `import Mod from "path"` replaces
    `import "path" as Mod`, and `import {A, B as C} from "path"` imports
    exported functions, structs, enums and constants to use bare, with an
    optional rename; `Mod.name` stays for functions, structs and enums; a
    one-off script migrates every `.agc`, golden and doc. **Module constants:**
    a top-level `NAME = expr` (or `export NAME: Type = expr`) in
    `UPPER_SNAKE_CASE`, never reassigned, read as `NAME` (a constant of another
    module only through a named import, never as `Mod.NAME`, as in Elixir). A
    plain literal is inlined in the bytecode; any other value is a constant
    expression (literals, collections, struct and enum construction, operators,
    other constants, and calls of effect-free builtins; no user function calls,
    no `while`) that the VM evaluates once before `main`, in dependency order.
    In order: 44a0-1 (**done**: the new import forms in both parsers and
    linkers, accepted next to the old form), 44a0-2 (**done**: the migration,
    the end of the old form, **Breaking:**, the docs and skills), 44a1 (VM and
    writer: bytecode format version 5, the Globals section, `GLOBAL` and
    `GLOBAL_SET`, loader checks; no language change; it can run in parallel with
    the checker port; **done, PR #265**), 44a2 (**done**; constants in both
    front ends: parsers, linkers, `CHECK-DECL-ORDER`, checker, lowering,
    bytecode writer, with `docs/grammar/`, the site, the skills and
    `CHANGELOG.md`; split in two PRs: 44a2-1, #270, the parsers, linkers and
    both checkers with `docs/grammar/`; 44a2-2, #271, the lowering, the writer,
    the VM fixtures, the site, the skills and `CHANGELOG.md`), then 44b (the
    lexer, done in PR #317), 44c (the parser and Unicode tables, done in PR
    #337), 44d (the linker and the builtin catalog, next) in `compiler/`, and
    44e (static data, only if start-up numbers ask for it). Step 4 (PRs #258 and
    #263) is merged: 44a0-2 changes one message text in `src/checker.rkt` (the
    import form in a help), and 44a2 changes both checkers, `src/checker.rkt`
    and `compiler/checker.agc`, in the same PR. Bytecode format versions: this
    takes 5, so the reservations of §41 and §42 move to 6 and 7
  - **Outcome:** The tables of the Agentica front end are values built once per
    run, a file names what it imports, and any program can name a fixed value at
    the top of a file

- **Order:** 7.2.9
  - **Next work:** **Done (2026-10-16; PRs #261–#311):** the tests moved
    from rackunit to Python `unittest` (stdlib only), with the live
    comparisons frozen under `tests/fixtures/frontend/frozen/`
    (`tools/refreeze.py` rewrites the goldens without Racket);
    design: [§18.7](../future/18-front-end-language.md#187-tests).
  - **Outcome:** The test suite runs the binary through one standard-library
    harness; each test lives in one framework

- **Order:** 22b
  - **Next work:** **After the bootstrap** (owner, 2026-10-15). New features,
    front end only, in `compiler/`: `agentica doc PATH` and
    `agentica help std/MODULE` ([§32](../future/32-doc-comments.md#32-doc-comments), part 22b; [§32.5
    and §32.6](../future/32-doc-comments.md#32-doc-comments))
  - **Outcome:** Agents and people read a module's API with `agentica doc
    std/http`, in text or JSON

- **Order:** 7.2b
  - **Next work:** **After the bootstrap** (owner, 2026-10-14). New features,
    VM-only (cont.), after row 22b, in `compiler/`: the semantic CLI
    for agents
    ([§39](../future/39-semantic-cli.md#39-semantic-cli-for-agents)): `agentica
    outline`, then `agentica symbol` and `agentica refs`, then `agentica
    type-at`, JSON first; front end and CLI only, nothing to run, no LSP; the
    full 6c round (step 10) measures it
  - **Outcome:** Agents list declarations, find definitions and references
    across modules, and get the checked type at a position, without reading
    whole files or guessing from `rg`

- **Order:** 7.5a
  - **Next work:** **Done (2026-10-16):** default parameter values (15a, in
    the [grammar's default parameters][grammar-defaults]), in `compiler/`;
    `std/logger` (14c, row 7.5) replaced its `_meta` functions with a
    `fields` default.
  - **Outcome:** Functions take default parameter values, checked at compile
    time

- **Order:** 7.6
  - **Next work:** **After the bootstrap** (each item changes the checker,
    now in `compiler/`). New features,
    VM-only (cont.): strict diagnostics first (phase 16,
    `docs/future/26-strict-diagnostics.md` §26, no warnings:
    `CHECK-UNUSED-IMPORT`, `CHECK-UNUSED-VARIABLE`, `CHECK-UNREACHABLE-CODE`,
    `CHECK-UNUSED-RESULT`, in the order 16a, 16c, 16b, 16d; front end only, each
    PR migrates the repo's programs); then Ruby typed idioms (phase 15,
    `docs/future/25-ruby-typed-idioms.md` §25, Part A, one way to do each
    thing): re-exports, value equality, lambdas, `File.open` with a block,
    heredocs (15b, 15d, 15e, 15i, 15j; 15c, `with`, was built earlier, see row
    7.2.7); one small PR each
  - **Outcome:** Unused imports, unused variables, unreachable code and ignored
    `Result` values are errors, and there are no warnings; agents write the Ruby
    forms they know, still checked, immutable and with one canonical form

- **Order:** 8.2
  - **Next work:** **The prelude and the Enumerable methods (15f) are done
    (2026-10-16)**, in `compiler/`, `stdlib/prelude/` and the VM; `format`
    (15k) is still deferred (row 7.6); `Lazy[T]` (17e) is **done**: lists,
    ranges and `Lazy.produce` (PR #421), then `File.foreach` and `ch.lazy`.
  - **Outcome:** Enumerable methods, written in Agentica, O(n) on the new lists

- **Order:** 8.3
  - **Next work:** **Done (2026-10-16, PR #326):** VM start-up cut, measured
    on the bootstrap build
    ([§18.5](../future/18-front-end-language.md#185-goals-and-targets)): the
    loader of the carried front end takes 8.3 ms, not 15, so a hello check
    is 17.5 ms, not 24.3. Numbers in
    [vm-benchmarks](../vm-benchmarks.md#speed-pass-vm-start-up-row-83).
  - **Outcome:** Each VM start costs less, and the test suite runs faster

- **Order:** 7.3
  - **Next work:** Iteration and concurrent collections (phase 17,
    `docs/future/27-iteration-and-concurrency.md` §27): `Task.map` (17a,
    **done**, PR #316); `Channel[T]` (17b) at row 7.2.1e; `Task.await`
    with a timeout (17c, built); `File.each_line` (row 7.2.1h);
    `Lazy[T]` (17e, **done**: PR #421 and the I/O sources).
  - **Outcome:** Programs run I/O for each item of a list N at a time, and build
    producer and consumer pipelines, with one form for each job

- **Order:** 7.4
  - **Next work:** New features, VM-only (cont.): the streaming items of phase
    20 (20e to 20g,
    [§30](../future/30-hybrid-http.md#3011-streaming-on-channels), the hybrid
    HTTP plan), built on the channels of 17b; then `TlsContext`
    ([§29](../future/29-tls-context.md#29-tls-contexts)),
    then ALPN (19c, owner 2026-10-16: the HTTP client stays small and opens its
    low layers,
    [§30.13][agentica-link-4])
  - **Outcome:** Programs stream HTTP bodies through channels, set up TLS with a
    `TlsContext`, and can write an HTTP/2 library on `TLS` with ALPN

- **Order:** 7.5
  - **Next work:** New features, VM-only (cont.): UDP, then logging and
    debugging (14c, **done**: `std/logger`, with no default parameter values and
    no flags; its Racket parts were data under the freeze of row 7.2.7), then
    the `Crypto`
    module (`docs/future/20-crypto.md` §20: hashes, HMAC, constant-time compare,
    random bytes, password hashing and AEAD on OpenSSL 3; needs `Bytes`). Binary
    data (row 7.2.4) and stack traces (row 7.2.5) moved to their own rows
  - **Outcome:** Programs send UDP; programs log with levels, fields and JSON
    lines, and sign, hash and encrypt

- **Order:** 7.7
  - **Next work:** VM metrics (phase 18, `docs/future/28-vm-metrics.md` §28),
    VM-only, no language change: 18a metrics derived from the VM's own state and
    the `.prom` file, 18b the `GET /metrics` endpoint, 18c the enabled-only
    hooks with the overhead check, then 18d memory diagnosis
    ([§28.12](../future/28-vm-metrics.md#2812-memory-diagnosis-18d): per-task
    allocation counters, which need channels (17b) done and, for handle bytes,
    the one-owner rule of 24b; and an on-demand dump of the top tasks); it needs
    only 7i (not the HTTP stack), and goes before the server measurement (7j)
  - **Outcome:** Prometheus scrapes a running VM and Grafana graphs its GC,
    tasks, run-queue delay and I/O; batch runs leave their exit code and totals
    for node_exporter; nothing costs anything while nobody asks

- **Order:** 7.8
  - **Next work:** **Deferred until after the bootstrap** (46c and 46d; 46a and
    46b may run earlier as VM-only rows, when no other VM PR is waiting),
    decided by the owner on 2026-10-15 (design and plan:
    [§46](../future/46-signals.md#46-signals)): signals that a program can
    handle, in four parts. 46a, subscription: the `Signal` enum and its
    subscription builtin (the name is decided in 46a), so a program handles
    TERM, INT, HUP, USR1 and USR2, and QUIT forces the exit. 46b, sending:
    `Process.signal`, `Process.spawn_group`, `Process.signal_group` and
    `System.signal`. 46c, the driver forwards a stop at once. 46d, `std/http`
    drains its handlers on a stop. 46a and 46b are VM C code and builtin table
    rows, which row 7.2.7 allows; that holds for option (B) of §46.3.1, and
    option (A) is a front-end change that its PR justifies against the freeze.
    46c and 46d come after 46b by the owner's order (§46.7 does not require it);
    46d is Agentica code in `std/http`
  - **Outcome:** A container entrypoint can stop its children and exit on its
    own terms, and an Agentica program can send signals to its children

- **Order:** 7.9
  - **Next work:** **Deferred until after the bootstrap**, decided by the owner
    on 2026-10-15 (design and plan:
    [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt)): a
    code formatter, `agentica fmt`, written in Agentica on the self-hosted lexer
    and parser. 47a, comments kept in a side list and attached to nodes; 47b,
    the printer and `--check` over `compiler/` and `stdlib/`; 47c, the CLI, the
    `max_line_width` key (the only `[style]` key today) and
    `CHECK-LINE-TOO-LONG` in `agentica check`, which replaces
    `tests/test_style_line_width.py`. 47d, the LSP format-document hook, is
    outside this order: it waits for the language server (§43, not scheduled).
    Row 7.10 (regular expressions) comes before this row, by the owner's
    decision of 2026-10-15.
  - **Outcome:** Every `.agc` file has one layout, checked in CI, and an editor
    can format a file with the compiler's own parser

- **Order:** 7.10
  - **Next work:** **Deferred until after the bootstrap**, decided by the owner
    on 2026-10-15 (design and plan:
    [§48](../future/48-regex.md#48-regular-expressions)): regular expressions,
    new library features, std first: `std/regex` in Agentica (a parser and a
    linear-time Pike VM, no backtracking), then the regex literal
    `/pattern/flags` (48b, `compiler/` only); a C matcher only if measured
    (48c). It comes before row 7.9 (the formatter), by the owner's decision of
    2026-10-15.
  - **Outcome:** A program searches, extracts, replaces and splits text with a
    pattern, written as a literal or a string, and no pattern can stall the VM

- **Order:** 7.11
  - **Next work:** **Planned**, not yet scheduled by the owner (design
    and plan: [§50](../future/50-test-functions.md#50-test-functions)):
    a `*_test.agc`
    file may have no `main`; its top-level `test_*` functions are its tests, and
    the front end adds the `main` that runs them (50a, `compiler/` only).
    Post-bootstrap step 6.
  - **Outcome:** A test file reads as a list of tests, with no `main` and no
    `Test.test` blocks

- **Order:** 7.12
  - **Next work:** **30a implemented; 30b planned** (design and plan:
    [§49](../future/49-type-aliases.md#49-type-aliases)): simple transparent
    aliases (`type Grid = List[List[Float]]`) are compiler-only, with no
    bytecode or VM change. Next, generic aliases (`type Matrix[T] =
    List[List[T]]`). Post-bootstrap step 6, before row 7.11 and before the path
    to the JIT.
  - **Outcome:** Long types get one name, with no runtime cost

- **Order:** 8.1
  - **Next work:** The rest of the VM layers (7l: opcode helpers, builtin
    metadata flags, the callback-builtin protocol; the header split is row
    7.2.1b); after the tasks PR, next to 7k
  - **Outcome:** The prerequisites of the JIT

- **Order:** 9
  - **Next work:** Server measurement on the VM (7j), with the source → result
    runner (7g); it also reads the VM metrics of phase 18 (GC, run-queue delay,
    I/O) while the load runs
  - **Outcome:** Requests/s, p50/p99 latency (also while a CPU-bound task runs),
    peak memory and real start-up, against Python as an outside reference

- **Order:** 9.1
  - **Next work:** JIT (7m, `docs/future/22-jit.md` §22): required; it comes
    after packages and the FFI
    ([§40.5](../future/40-native-code.md#405-order)). It follows 7l and 7j.
    JIT code must follow the multicore rules of row 11 (§16)
  - **Outcome:** Hot functions run as native code with the same results

- **Order:** 11
  - **Next work:** Multicore schedulers (7h item): **built behind a test
    switch (2026-10-19/20)**: one I/O thread and N scheduler threads, HTTP
    included (std/http). Still to do: run N > 1 without the switch, and the
    remaining refused builtins (`docs/vm/16-architecture.md` §16.9)
  - **Outcome:** One I/O thread and N schedulers, N from `--schedulers`

- **Order:** 10
  - **Next work:** Evaluation round: Agentica against typed Python on harder
    tasks (6c), the full round after the pilot of step 7.2.2, with the semantic
    CLI of phase 26 (§39.12). It waits until after the bootstrap (row 7.2.7), by
    the owner's decision of 2026-10-14
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
    (single-threaded; needs the 7g benchmark script (done), the real
    applications, faster lists (8d) and the VM `IO` library
    (`docs/vm/12-testing-and-pr-plan.md` §12.2 item 6a, done)) goes before MCP;
    round 2 (concurrent programs) needs tasks on the VM (7h) and covers
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
([§18](../future/18-front-end-language.md)), decided by the owner on 2026-10-13,
are
in the order from row 7.2.7 on, after their prerequisites (rows 8 and 7.2.4 to
7.2.6; [§18.6](../future/18-front-end-language.md#186-order)). Its steps (§18.3)
are
PRs, not rows of this table. The release cut right after step 7b was 0.3.0,
the last one with the Racket front end (owner decision, 2026-10-15).

The owner set this order for the work after the bootstrap on 2026-10-15 and
revised it on 2026-10-16, 2026-10-19 (multicore moved ahead of the JIT) and
2026-10-20 (packages before the FFI,
[§40.5](../future/40-native-code.md#405-order)): the rows that waited for the
bootstrap come first, then the path to the JIT (row 9.1, which should also speed
up `agentica test`), and the other features after the JIT. The package system
and the FFI sit on that path. Multicore (row 11) and the native Windows and
macOS releases were done ahead of this order.

1. **Done (2026-10-16, PR #312)**: release 0.4.0, the first release with the
   single binary ([§18.3](../future/18-front-end-language.md#183-port)).
2. **Done (2026-10-16, PR #313)**: delete the Racket front end, freeze
   `vm/unicode_data.c` as checked-in source, tag `bootstrap-racket`
   (§18.2).
3. A speed pass on the self-hosted front end
   ([§18.5](../future/18-front-end-language.md#185-goals-and-targets)):
   **done (2026-10-16, PRs #315, #317, #319, #326):** the `agentica test`
   start-up (0.87 s to 0.05 s), the lexer (half the steps), the
   interpreter loop, and the loader (15 ms to 8.3 ms); shared small
   values ([§34](../future/34-shared-small-values.md)). Numbers in
   [vm-benchmarks](../vm-benchmarks.md). Still to do: the parser, for
   room under 100 ms for `stdlib/bdd/gherkin.agc`.
4. **Done (2026-10-16)**: default parameter values (row 7.5a, in the
   [grammar's default parameters][grammar-defaults]), in `compiler/`.
5. **Done (2026-10-16, PRs #322 and #325):** `case` guards, nested
   patterns and the `<<~NAME` heredoc, in `compiler/` only (the two-step
   stage0 refresh of §18.2 is a later PR).
6. The other rows that waited for the bootstrap: the prelude (row 8.2),
   strict diagnostics (row 7.6), `agentica doc` and `help` (row 22b), the
   44b–44d table rewrites (**done 2026-10-16**), type aliases (row 7.12,
   §49: 49a done, then generic 49b), test functions without `main`
   (row 7.11, §50), and `Task.map` (**done**, 17a, PR #316).
7. The path to the JIT: the rest of the VM layers (row 8.1), VM metrics (row
   7.7), the server measurement (row 9), the package system
   ([§45](../future/45-packages.md)), UDP (row 7.5, issue #399), the FFI and
   native module header ([§40](../future/40-native-code.md)), then the JIT
   (row 9.1). The native Windows and macOS builds are done (release
   0.5.0-beta.1); the gaps Windows still has close first, for the 0.5.0
   release without beta. UDP closes the networking part of the stable core
   (below); its design waits for the owner's approval (#399).
8. After the JIT: the semantic CLI (row 7.2b,
   postponed by the owner on 2026-10-16); signals (row 7.8,
[§46](../future/46-signals.md#46-signals),
   parts 46a to 46d; 46c also lets `agentica test` clean its run directory on
   Ctrl-C); regular expressions (row 7.10,
   [§48](../future/48-regex.md#48-regular-expressions)) before the formatter
   (row 7.9, [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt)).
   Regex first needs the owner's answer on the Ruby anchors question of
   [§48.10](../future/48-regex.md#4810-decisions-and-open-questions); the
   formatter needs the heredoc of step 5 and the open questions of
   [§47.9](../future/47-formatter.md#479-open-questions). Also later, in no
   fixed order: HTTP streaming and `TlsContext` (row 7.4), the
   6c evaluation round (row 10) and the Unicode generator.

Stable core (owner decision, 2026-10-20). The C core stays small, safe and
stable: the language, the VM, the GC, the scheduler, tasks and channels, JSON,
and the OS primitives that need the event loop (files, processes, timers, TCP,
TLS and UDP). UDP is in the core, not an extension, because a socket must wait
without blocking the scheduler, with timeouts and cancel. Everything else is an
extension: first a package written in Agentica
([§45](../future/45-packages.md)), and a native module through the FFI
([§40](../future/40-native-code.md)) only when it needs a library in C, C++ or
Rust. After UDP and the FFI land, the core changes only for bugs, platforms and
speed (the JIT).

Designed, not scheduled: dates and times (§41,
[`docs/future/41-dates-and-times.md`](../future/41-dates-and-times.md)).
It has no row in this table. Its builtin types are checker changes, so they
come after the Agentica front end (§41.13), as the owner decided on 2026-10-15.
Its `Time.monotonic_ns` part is independent and has landed (§41.10).

Designed, not scheduled: sized numeric types (§42,
[`docs/future/42-sized-numeric-types.md`](../future/42-sized-numeric-types.md)).
It has no row in this table. Its types are checker changes, so they start
after the bootstrap, in the Agentica front end (§42.14).

Idea, not scheduled: a language server ([§43](../future/43-language-server.md)).
It has no row in this table. It would reuse the §39 commands and the §32 doc
comments, so it can only start after them (and is easiest on the self-hosted
front end of §18).

Designed: packages (§45,
[`docs/future/45-packages.md`](../future/45-packages.md)). It has no row in this
table. Its first step, the TOML parser `std/toml` (45-0), is a std module and
landed before the bootstrap (done). It sits on the path to the JIT, before the
FFI (step 7 above). The phases after 45-0 wait for the owner's answers to
§45.14.

After steps 1–2, target everyday scripts and automation. After steps 13 and 15
(real applications and MCP), target larger general-purpose programs. Keep
diagnostics, behavior tests, grammar, and the self-contained programming
reference part of every phase. Specify new APIs in `docs/future/` before
implementation; move them into the grammar only when they land. Detailed pending
work appears after the completed foundations below.

### Rules for the catch-up and new features

- Work is tested with golden outputs and independent Node/Python peers. The
  catch-up (TCP, TLS, HTTP 20a, BDD on the VM) removed each fallback, and 7i
  deleted the evaluator.
- New features are VM-only. They have no Racket twin.
- The Racket front end is deleted (row 7.2.7, post-bootstrap step 2).
  Every language change goes into the Agentica front end (`compiler/`,
  [§18](../future/18-front-end-language.md)); a PR may relax a default rule when
  following it costs more than it saves, and says which rule and why.
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
  built on the `Int` builtins, text formatting, algorithms. They run on the VM
  with no VM work, and the golden fixtures test them.
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
  scheduler is a C builtin
  instead (`Task.await` with a timeout, §27.3).
- Two builtin modules are std-only: `HttpWire` (phase 20,
  `docs/vm/10-io-http.md` §10.7), the framing layer under `std/http`, and
  `LogRegistry` (the grammar's logging section), the registry under
  `std/logger`. A public raw layer next to `std/http` would be a second way to
  do HTTP, and a public registry would let user code change the handlers without
  the `Logger` functions. So the linker lets only modules embedded from
  `stdlib/` call them (`std_only_name?` in `compiler/builtins.agc`),
  and user code
  gets `CHECK-UNKNOWN-NAME` with a help that names the std module to import.
- Not retroactive: existing builtins, JSON included, stay as they are.


## Files

This file holds what matters now: the order above and the general rules. Each
open or partly open part of the plan has its own file. Phase numbers stay as
they were, so "phase 13" is in `13-binary-data.md` and "7h" is in `07-vm.md`.

- **File:** [`06-validation.md`](06-validation.md)
  - **Contents:** Phase 6: validate the language design, with 6c (Agentica
    against typed Python)

- **File:** [`07-vm.md`](07-vm.md)
  - **Contents:** Phase 7: bytecode VM (7a to 7m; the design is in
    [`docs/vm/`](../vm/README.md))

- **File:** [`08-data-structures.md`](08-data-structures.md)
  - **Contents:** Phase 8: core data structures

- **File:** [`12-benchmarks.md`](12-benchmarks.md)
  - **Contents:** Phase 12: cross-language benchmarks

- **File:** [`13-binary-data.md`](13-binary-data.md)
  - **Contents:** Phase 13: binary data

- **File:** [`14-logging.md`](14-logging.md)
  - **Contents:** Phase 14: logging and debugging

- **File:** [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md)
  - **Contents:** Phase 21: BDD in Agentica (`std/bdd`, a runner and a child VM
    per scenario; catch-up item 7h)

- **File:** [`23-digit-separators.md`](23-digit-separators.md)
  - **Contents:** Phase 23: digit separators in number literals (`1_000`)

- **File:** [`24-task-crash-isolation.md`](24-task-crash-isolation.md)
  - **Contents:** Phase 24: task crash isolation (a crash ends only its task)

- **File:** [`25-unit-tests.md`](25-unit-tests.md)
  - **Contents:** Phase 25: unit tests (the `Test` module, `*_test.agc` in
    `agentica test`)

- **File:**
  [`pending-general-programming-and-mcp.md`][agentica-link-5]
  - **Contents:** Pending work: general programming and MCP (everyday library,
    typed JSON, modules, real applications, MCP)

- **File:** [`ruby-style-ergonomics.md`](ruby-style-ergonomics.md)
  - **Contents:** Ruby-style ergonomics (complete)

- **File:** [`later-extensions.md`](later-extensions.md)
  - **Contents:** Later extensions and open decisions

- **File:** [`01-foundations.md`](01-foundations.md)
  - **Contents:** Completed phases 1 to 5n: the front end, the standard library
    before validation, and the completed foundations (5j, BDD features, 5j2, 5k,
    5n); the open 5d3 and 6a items

Planned syntax is in [`docs/future/`](../future/README.md).

[agentica-link-1]: ../future/27-iteration-and-concurrency.md
[agentica-link-2]: ../grammar/06c-tasks-and-tests.md#agentica-test
[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
[agentica-link-4]: ../future/30-hybrid-http.md
[agentica-link-5]: pending-general-programming-and-mcp.md
[grammar-defaults]: ../grammar/06-semantics.md#default-parameter-values
[grammar-syntax-precedence]: ../grammar/05-syntax.md#expressions-and-precedence
