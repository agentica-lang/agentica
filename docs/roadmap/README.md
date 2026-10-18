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
    differential tests became golden tests; the release ships `agentica-vm`
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
    [§36](../future/36-unit-tests.md#36-unit-tests-test): the builtin `Test`
    module and `*_test.agc` files in `agentica test`; after phase 24, so a crash
    fails one test; done), then HTTP 20c (done: the `std/http` server, which
    brings back an HTTP server and `examples/http_server.agc`, and also takes
    what was left of 20d, since 7i did the switch; it does not depend on phases
    24 and 25 and could go before them; [phase 20](20-hybrid-http.md)); VM-only.
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
  - **Next work:** **Complete:** VM architecture note
    ([§16](../vm/16-architecture.md#16-vm-architecture)), decided by the owner
    on 2026-10-13, docs only: N schedulers that pull from one global run queue,
    one I/O thread (the main thread) with the only libuv loop, the libuv pool
    for bounded blocking work, intrusive queues with one mutex each, and how a
    task parks and wakes. [§10.2.3](../vm/10-io-multicore.md) now keeps the
    rules per thread. More than one scheduler stays gated (step 11). The owner
    set this order after HTTP 20c: this note, then row 7.2.1b, then rows 7.2.1d,
    7.2.1e and 7.2.1f, then row 7.2.1a, then the pilot (row 7.2.2). The table
    order below is that order
  - **Outcome:** One picture of the threads, the queues and who owns what,
    before code is written on top of it

- **Order:** 7.2.1b
  - **Next work:** **Complete:** VM layers, the first part of
    [7l](07-vm.md#7l-vm-layers), planned by the owner on 2026-10-13, VM-only, no
    behavior change ([§15](../vm/15-layers.md#15-vm-layers)): three layers with
    one-way dependencies (core, services, adapters) and a driver that wires
    them, one small port between the services and the core (park a task, submit
    a job with its timeout, register and close a handle; the functions that
    exist today), `vm/agc.h` split into `value.h`, `port.h`, `core.h` and
    `services.h`, and a CI check (`vm/tools/check-layers.sh`, run by `make
    vm-layers`) with the include rules (`rg`: a core file includes no service
    header, a service includes no `core.h`, a third-party header stays in its
    file) and the link rules (`nm`: no core object uses a service or adapter
    symbol, an adapter uses only the memory functions of the core). Two small
    mechanical PRs, both done: the moves, then the headers and the check. It
    waited for HTTP 20c and for the blocked-read fix of row 7.2.1a (both change
    `input.c`, `files.c` and the HTTP services; both are done). It comes before
    25c and 24b of row 7.2.1a: 25c adds process builtins and 24b changes handle
    ownership, so both should be written on the port. The rest of 7l (opcode
    helpers, builtin metadata flags, the callback-builtin protocol) stays at row
    8.1
  - **Outcome:** The core never calls a service by name, and CI keeps it so; 25c
    and 24b are written on a named port

- **Order:** 7.2.1d
  - **Next work:** **Complete (asynchronous process close, then the flush
    limit):** small PRs, VM-only, decided by the owner on 2026-10-13:
    asynchronous process close and an always-on file-flush limit
    ([§14.1](../vm/14-core-invariants.md#141-waiting),
    [§14.4](../vm/14-core-invariants.md#144-ending)). libuv's exit callback
    reaps the child; `Process.close` parks the calling task on a job with a
    timer; a close during a crash is fire-and-forget; this removes the 1 s
    `nanosleep` reap on the loop thread. The file flush gets a limit that is
    always on: 30 seconds by default, set with `--flush-timeout MS` or an
    environment variable (for example `AGENTICA_FLUSH_TIMEOUT_MS`), with no way
    to turn it off; this replaces the earlier choice of phase 24 (no limit by
    default). After the VM layers (row 7.2.1b)
  - **Outcome:** `Process.close` never blocks the loop thread, and the end of a
    run is always bounded

- **Order:** 7.2.1e
  - **Next work:** **Complete:** `Channel[T]` (17b,
    [§27.2](../future/27-iteration-and-concurrency.md#272-channels)), moved
    earlier by the owner on 2026-10-13: the spec first (docs only, done), then
    the implementation, because stdout and stderr (row 7.2.1f) build on its
    parking mechanism. 17a (`Task.map`) stays at row 7.3; the tests that need
    `Task.map` move to 17a's PR ([phase 17](17-iteration-and-concurrency.md))
  - **Outcome:** Producer and consumer pipelines with one form, and a parking
    mechanism for bounded buffers

- **Order:** 7.2.1g
  - **Next work:** **Complete:** Pipe operator `\|>` (15l, in the
    [grammar's expression rules][grammar-syntax-precedence]), decided by the
    owner on 2026-10-14: a small front-end PR (lexer, parser,
    one checker rule; no VM change) after channels (row 7.2.1e) and before
    stdout and stderr
    on the loop (row 7.2.1f). The owner chose it over methods on structs or
    Lua-style metatables, which stay decided against
    ([§25.13](../future/25-ruby-typed-idioms.md#2513-decided-against-part-c))
  - **Outcome:** User functions chain left to right, with one form per call

- **Order:** 7.2.1f
  - **Next work:** **Complete:** stdout and stderr on the loop, decided by the
    owner on 2026-10-13, VM-only: `puts`, `print`, `IO.inspect` and `IO.warn`
    stop being blocking writes
    ([§14.1](../vm/14-core-invariants.md#141-waiting)) and park the task on the
    parking mechanism of channels (row 7.2.1e). One 64 KiB buffer and a FIFO of
    writers per stream (one for both when they are the same target), the I/O
    thread is the only writer, `/proc/self/fd` reopen as for stdin, a duplicated
    socket, notices that wait for room; spec in
    [§10.2.2](../vm/10-io-scheduler.md#1022-the-loop)
  - **Outcome:** A full stdout pipe no longer stalls every task

- **Order:** 7.2.1h
  - **Next work:** **Complete:** `File.each_line` (17d,
    [§27.4][agentica-link-1]
    step 1), decided by the owner on 2026-10-14, VM-only builtin, a block per
    line with a bounded read buffer
  - **Outcome:** Big files are read line by line in bounded memory with one call

- **Order:** 7.2.1a
  - **Next work:** **Complete:** core simplification, decided by the owner on
    2026-10-13, VM-only, held to the [VM core
    invariants](../vm/14-core-invariants.md#14-vm-core-invariants) (§14).
    Outside the order and free to land at any time, being a bug fix: a separate
    fix PR for blocked reads at exit (**done**, PRs #162 and #164: §14.4 one
    exit path and stop signals; §14.1 stdin, FIFOs and character devices read
    non-blocking on the loop, not in the pool). Then, after the VM layers (row
    7.2.1b) and rows 7.2.1d to 7.2.1f (the owner's order of 2026-10-13), and
    before the pilot, two small PRs: first the child protocol on its own channel
    (**done**, [25c](25-unit-tests.md),
    [§36.6][agentica-link-2]):
    `Process.spawn_channel` (a sibling of `spawn_captured`) opens an extra
    bidirectional socket pair (fd 3 and the environment marker
    `AGENTICA_CHANNEL=3`) with the builtins `channel_read_line`, `channel_send`,
    `channel_close` and `read_available` on the parent side and a pair
    `Process.parent_read_line` and `Process.parent_send` on the child side
    ([§10.4](../vm/10-io-processes.md)), unit-test and BDD children (scenario
    and list modes) use it, and the VM dropped 25b's token, reserved stdin,
    private fd 0 and `mid_line` with `agc_write_record`; then one
    handle-ownership rule (**done**, [24b](24-task-crash-isolation.md),
    [handle ownership][task-rules],
    §14.5): a handle belongs to the task that opened it, is closed when that
    task ends, and moves to another task only explicitly, with
    `Task.spawn_owning`, replacing three mechanisms (the spawn move,
    `agc_give_owned` and 20c's `HttpWire.spawn` group registration, which became
    a use of the explicit form); it needed 20c
  - **Outcome:** Tests read their own stdin and print freely; one rule for who
    closes a handle; a smaller core before it is measured and built on

- **Order:** 7.2.2
  - **Next work:** **Complete** (2026-10-14, rounds 9 to 11 of `docs/eval.md`;
    the owner reviews the results before the next rows): Evaluation pilot, after
    rows 7.2.1, 7.2.1b, 7.2.1d, 7.2.1e, 7.2.1f and 7.2.1a (decided by the owner
    on 2026-10-13; [phase
    6c](06-validation.md#phase-6c-agentica-against-typed-python)): first a
    regression round of the `binary` arm on the VM, with the two models and
    tasks of rounds 6 (DeepSeek) and 8 (GLM 5.3 flash), t1–t8, 3 reps per task,
    compared with those rounds in `docs/eval.md`; then a first 6c pilot: about
    20 tasks (the 8 of today plus about 12 of the harder kinds of 6c, each with
    hidden tests and reference solutions in Agentica and typed Python), the same
    agent, two models (those of rounds 6 and 8) and budget for the Agentica
    `skill` arm and a typed Python arm, 3 reps per cell; it measures functional
    success, tokens, attempts, compile and check errors and time to a correct
    solution. It needed the 6c typed Python arm and the pilot's tasks first (the
    first two items of 6c, done). Its results decide the order of the rows that
    follow; the full 6c round, with enough reps for its claims, stays at step 10
  - **Outcome:** Evidence that the VM-only language did not regress for agents,
    and a first answer on Agentica against typed Python, early enough to change
    the plan

- **Order:** 7.2.3
  - **Next work:** **Complete** (2026-10-14, PRs #200, #201 and #204, round 12
    of [`docs/eval.md`](../eval.md); the owner's order of 2026-10-14, the first
    row after 7.2.2): a smaller `agentica-programming` skill, more diagnostic
    hints, and a re-measure of the `skill` arm of [`docs/eval.md`](../eval.md).
    In order: cut the skill's token cost (a much smaller `SKILL.md`, one line
    per builtin in the references), add hints for the common errors of the
    evaluation rounds, then re-measure the `skill` arm on the same tasks and
    models
  - **Outcome:** Agents spend fewer tokens to learn the language, the common
    errors come with a hint, and the re-measure shows whether agents fail less

- **Order:** 7.2a
  - **Next work:** New features, VM-only, after rows 7.2.1 and 7.2.2: doc
    comments ([phase 22](22-doc-comments.md), part 22a,
    [§32](../future/32-doc-comments.md#32-doc-comments): `##` lines, front end
    only; `agentica doc` is row 22b, after the bootstrap), then digit separators
    ([phase 23](23-digit-separators.md),
    the grammar's [literal rules](../grammar/04-lexical.md#literals): `1_000`,
    lexer
    only). This is the last new language feature in the Racket front end; row
    7.2.7 freezes that front end after it
  - **Outcome:** Programs carry `##` docs in their source, and write long
    numbers as `1_000_000`

- **Order:** 8
  - **Next work:** Faster lists (8d, **complete**: the persistent vector, then
    step 3, unboxed `List[Int]` and `List[Float]` leaves, which the VM decides
    by itself and so needed no front-end work before the freeze, row 7.2.7): a
    persistent vector behind `List`, before any instruction-dispatch
    micro-optimization (7g); then the review of what the VM inherited from
    Racket (7k), next to the 7g hot spots
  - **Outcome:** `push` stops copying the whole list; list-heavy programs stop
    being O(n²); the VM keeps Racket's rules only where they are good on their
    own

- **Order:** 7.2.4
  - **Next work:** **Complete** (PRs #220 and #223): Binary data (phase 13,
    [`docs/future/23-binary-data.md`
    §23](../future/23-binary-data.md#23-binary-data)), taken out of row 7.5 by
    the owner on 2026-10-14: the `Int` and `Float` bit builtins (13a) and
    `std/binary` (13b), with their tests and docs ([phase
    13](13-binary-data.md)). It comes before the freeze, because the bytecode
    writer of the self-hosted front end needs it
    ([§18.4](../future/18-front-end-language.md#184-prerequisites))
  - **Outcome:** Programs read and write binary numbers with `std/binary`

- **Order:** 7.2.5
  - **Next work:** **Complete** (2026-10-14, PR #225): Stack traces on runtime
    errors (14b, `docs/vm/02-reference-behavior.md`), taken
    out of row 7.5 by the owner on 2026-10-14: [phase 14](14-logging.md), always
    on in the plain, `--ai` and `--json` formats. It comes before the freeze,
    since agents and the self-hosted compiler both need the call stack
    ([§18.4](../future/18-front-end-language.md#184-prerequisites))
  - **Outcome:** Agents see the call stack of a runtime error, and a crash in
    the self-hosted compiler shows where it happened

- **Order:** 7.2.6
  - **Next work:** **Complete** (2026-10-14, PR #222): OS builtins the
    self-hosted front end needs, from
    [§18.4](../future/18-front-end-language.md#184-prerequisites),
    decided by the owner on 2026-10-14: reading environment variables
    (`AGENTICA_PATH`, `XDG_DATA_HOME` and the home directory) and a real-path
    builtin that resolves symbolic links (module identity and the `pkg/` escape
    check). Both are OS builtins in C (exception 1 of the std-first rule),
    listed in the `src/builtins.rkt` table: `System.env(name) -> Result[String]`
    and `Path.real(path) -> Result[String]`, with no new flag. The other partly
    missing items of §18.4 (binary output, the BDD driver's process and file
    calls, the hand-off to the VM) are needed from step 6 on, so they are not in
    this row
  - **Outcome:** The linker of the self-hosted front end finds `std/` and `pkg/`
    modules and checks their real paths, as the Racket linker does

- **Order:** 7.2.7
  - **Next work:** **Done (2026-10-16; started 2026-10-15; the Racket front end
    is deleted, post-bootstrap step 2); PRs #237, #245, #254, #258, #263, #282,
    #286, #288, #294, #297, #298, #299, #301, #310, #311):** the freeze is in
    force and the port’s steps 1 (the lexer), 2 (the parser, with
    `PARSE-TOO-DEEP`), 3
    (the modules and linker) and 4 (the builtin catalog, PR #258, and the
    checker, with `CHECK-TOO-DEEP`, PR #263; module constants, row 7.2.8,
    excepted), 5 (lowering, with module constants, PR #282) and 6 (the bytecode
    writer, PR #286), all in `compiler/`, and 7 (the BDD driver: 7a, the OS
    builtins it needs, PR #288, audited in
    [§18.4](../future/18-front-end-language.md#184-prerequisites); 7b,
    the driver itself, `compiler/bdd.agc`, PR #294, which relaxes the freeze
    only for the hand-off in `src/bdd-driver.rkt` and `src/main.rkt`) are done;
    step 8 follows, 8a (the command line in Agentica, PR #299, which relaxes the
    freeze only to read the plain file `VERSION` in `src/version.rkt` and to
    pass `--version` in `src/bdd-driver.rkt`) is done, 8b (the single binary and
    the fixed point, PR #298), 8c (the frozen goldens, PR #297), 8d-1 (the tests
    that needed Racket for no good reason, PR #301) and 8d-2 (the switch:
    `dist/agentica` is the single binary, built from the checked-in
    `bootstrap/stage0.agcb`; `agentica run` runs a compiled file; `agentica-vm`,
    `AGENTICA_VM`, `src/vm-launch.rkt` and `src/bdd-driver.rkt` are gone; the
    release ships `agentica` alone) are done; 8d-3 (the test suite and CI need
    no Racket: the rackunit files, their make targets and CI steps are gone, PR
    #311) is done too, so step 8 is complete. The last PR (#313) deleted `src/`,
    the table generators in `tools/` and the Racket CI jobs, froze
    `vm/unicode_data.c` as checked-in source (option A of the owner's Unicode
    decision; a generator over pinned Unicode Character Database files, written
    in Agentica, is a later PR and must reproduce the file byte for byte) and
    left `compiler/builtins_data.agc`, `check_tables.agc` and
    `unicode_table.agc` as hand-edited sources; the parent commit of its merge
    is tagged `bootstrap-racket`. The text below is the history of the freeze.
    **Freeze the Racket front end and start the port’s step 1** (the port of the
    lexer,
    [§18.3](../future/18-front-end-language.md#183-port)), decided by the
    owner on 2026-10-14. Freeze means, by default: from this row on, the Racket
    front end (`src/`) takes no new syntax and no new checker rules. Its only
    changes are bug fixes and the data this row lists: new rows in the
    `src/builtins.rkt` table that use an existing checker rule tag or none, with
    the matching name in the `vm-builtins` list of `src/lower.rkt` (the owner
    confirmed these on 2026-10-14); new entries in `builtin-records` and
    `builtin-enum-declarations` (`src/builtin-types.rkt`) whose types the
    checker, lowering and bytecode writer already handle, with a record's name
    in the record list of `src/lower.rkt`; the module registry line in
    `src/stdlib.rkt`; the `std-only-modules` list and, for a std-only module,
    its name in the reserved type names of `src/checker.rkt`; and message texts
    that name the right std module (a message fix, not a rule). The 2026-10-15
    items are the owner's decision (the freeze), and so is the change
    in `src/lower.rkt` for an enum field of a builtin record, which relaxes this
    list for those lines. A new checker rule, tag, syntax or construction rule
    is not data. Every language change after this row goes into the Agentica
    front end (`compiler/`,
    [§18.2](../future/18-front-end-language.md#182-bootstrap)). These rules are
    defaults and may be relaxed when following them costs more than it saves;
    the PR says which rule it relaxes and why. Relaxed so far:
    `CHECK-DECL-ORDER`, the fixed declaration order of a file (a small style
    rule in `src/modules.rkt`, on the owner's request; the checker port carries
    it); `Set[T]` (8b: the type, the `Set.*` builtin rows, their checker rules
    and the `for` lowering, on the owner's decision of 2026-10-15 because
    `compiler/` uses it; the checker port carries it); `value.with(field: x)`
    (15c: a syntax form in both parsers, the checker rules, a privacy predicate
    in the linker and the `STRUCT_WITH` opcode with bytecode format version 4,
    on the owner's decision of 2026-10-15 because `compiler/` uses immutable
    struct updates; the checker and modules ports carry it); `CHECK-TOO-DEEP`
    (port step 4: a limit of 1,000 levels of expressions and statements in
    `src/checker.rkt`, the checker's counterpart of `PARSE-TOO-DEEP`, because a
    tree can be deeper than the parser's limit and the Agentica checker recurses
    on it within the VM call limit of 10,000; with it, a fix for a Racket
    exception when a generic enum is given where another one is expected);
    module constants (row 7.2.8, 44a2: the declaration in both parsers, the
    linker, both checkers and the lowering in `src/lower.rkt` with bytecode
    format version 5, on the owner's decision of 2026-10-15 because `compiler/`
    keeps its tables as constants; the Agentica checker and the Agentica
    lowering of step 5 carry them); the std list (port step 8b, PR #298: the
    module registry of `src/stdlib.rkt` is built by a macro from the plain file
    `stdlib/MODULES`, one path per line, instead of one line per module, because
    the Makefile embeds the same list in the single binary; a test checks the
    file against `stdlib/`, and the two builtin rows of `FrontEnd.*` with their
    `vm-builtins` names are the data the freeze already allows); the switch
    (port
    step 8d-2, PR #310: it relaxes the rule "only bug fixes and data" for
    `src/main.rkt` alone, because `agentica-vm` is gone and the oracle still has
    to run programs. `src/vm-launch.rkt` and `src/bdd-driver.rkt` are deleted,
    as the step requires. `src/main.rkt` gets `find-binary` (it finds
    `dist/agentica`, as `find-vm` found the VM), `stop-vm` with its FFI `kill`
    and `call-noting-break` (moved from `src/vm-launch.rkt`, same behavior), the
    lines of `agentica run` in the help and usage texts (message texts, so that
    they match the binary's), and a stub for `test` that says that `test` is the
    binary's and exits 2. The oracle runs a program with `dist/agentica run`. No
    syntax, checker or lowering rule changes, and everything goes with Racket);
    the version file (port step 8a, PR #299: `src/version.rkt` embeds the one
    line of `VERSION` when it is compiled, instead of holding the number, and
    `src/bdd-driver.rkt` passes it to the driver as `--version`, because the
    writer in `compiler/` takes the version as an input and the Makefile, the
    release and the VM read the same file)
  - **Outcome:** The Racket front end stops growing; each later language change
    is written once, in Agentica, and the ports of §18.3 run in order, one PR
    per step Step 8 lands as four PRs, 8a to 8d
    ([§18.3](../future/18-front-end-language.md#183-port)), decided by the
    owner on 2026-10-15

- **Order:** 7.2.8
  - **Next work:** **Started (2026-10-15, 44a0-1 PR #262, 44a0-2 PR #268, 44a2
    PRs #270 and #271; design: [§44](../future/44-module-constants.md)), decided
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
  - **Next work:** **Done (2026-10-16; phase 0 PR #261, phase 1 PRs #264, #266,
    #267, #269, #274, #276, #279, phase 3 PRs #297, #301, #310 and #311; design:
    [§18.7](../future/18-front-end-language.md#187-tests),
    decided by the owner on 2026-10-15).** The tests move from rackunit to
    Python `unittest` (standard library only, no packages), in four phases: 0,
    the shared helper and the make targets, with one small area as the proof; 1,
    the VM and runtime, network and process, BDD and CLI areas, one per PR; 2,
    the golden parts of the front-end tests; 3, with 8c and 8d of step 8 (8c,
    8d-1, 8d-2 and 8d-3 are done: 8d-3 removed rackunit), the live comparisons
    frozen into goldens and rackunit removed. The phases run beside the port’s
    steps 4
    to 8 and §44; phase 3 is 8c (done: the live comparisons are frozen under
    `tests/fixtures/frontend/frozen/`, the golden comparisons of phase 2 for the
    front end moved with them, and `tools/refreeze.py` rewrites the goldens
    without Racket) and 8d of step 8
  - **Outcome:** The test suite runs the binary through one standard-library
    harness; each test lives in one framework, and Racket leaves the tests with
    the front end

- **Order:** 22b
  - **Next work:** **Deferred until after the bootstrap**, decided by the owner
    on 2026-10-15, because the `agentica doc` and `help` work is in
    `src/main.rkt` and a new `src/docs.rkt`, Racket front-end work that the port
    would then redo. New features, front end only: `agentica doc PATH` and
    `agentica help std/MODULE` ([phase 22](22-doc-comments.md), part 22b; [§32.5
    and §32.6](../future/32-doc-comments.md#32-doc-comments))
  - **Outcome:** Agents and people read a module's API with `agentica doc
    std/http`, in text or JSON

- **Order:** 7.2b
  - **Next work:** **Deferred until after the bootstrap**, decided by the owner
    on 2026-10-14, because it extends the Racket front end, which the port would
    then redo. New features, VM-only (cont.), after row 22b: the semantic CLI
    for agents ([phase 26](26-semantic-cli.md),
    [§39](../future/39-semantic-cli.md#39-semantic-cli-for-agents)): `agentica
    outline`, then `agentica symbol` and `agentica refs`, then `agentica
    type-at`, JSON first; front end and CLI only, nothing to run, no LSP; the
    full 6c round (step 10) measures it
  - **Outcome:** Agents list declarations, find definitions and references
    across modules, and get the checked type at a position, without reading
    whole files or guessing from `rg`

- **Order:** 7.5a
  - **Next work:** **Done (2026-10-16)**, in `compiler/` after the bootstrap (it
    was deferred because it would have changed the Racket front end). Default
    parameter values (15a, in the
    [grammar's default parameters][grammar-defaults]): front end only; split
    out of row 7.5 on 2026-10-14. `std/logger` (14c, row 7.5) did not need it:
    until it landed, the API had two functions per level
    (decided on 2026-10-15), and
    the `_meta` functions are gone now
  - **Outcome:** Functions take default parameter values, checked at compile
    time, and `std/logger` replaces its `_meta` functions with a `fields`
    default

- **Order:** 7.6
  - **Next work:** **Deferred until after the bootstrap**, because each item
    changes the Racket checker, which the port would then redo. New features,
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
    (2026-10-16)**, in `compiler/`, `stdlib/prelude/` and the VM; `format` (15k)
    and `Stream[T]` (17e) are still deferred. It was deferred until after the
    bootstrap, because the prelude changes the Racket front end, which the port
    would then redo. Ruby typed idioms, prelude part (15f, 15k): the compiler
    prelude with the Enumerable methods, then `format` (which is still
    [§25.11](../future/25-ruby-typed-idioms.md#2511-format)); after faster lists
    (8d), since the prelude's cost contract needs them; then `Stream[T]` (17e,
    `docs/future/27-iteration-and-concurrency.md` §27.4 step 2), which comes
    with the prelude
  - **Outcome:** Enumerable methods, `format` and `Stream[T]`, written in
    Agentica, O(n) on the new lists

- **Order:** 8.3
  - **Next work:** **Done (2026-10-16, PR #326)**, after the bootstrap, because
    the bootstrap embeds the front end in the VM binary and the cut was measured
    on that build
    ([§18.5](../future/18-front-end-language.md#185-goals-and-targets)). VM
    start-up cost, a small perf item ([7g](07-vm.md#7g-speed-check)). A sampling
    profile and timers between the sections of the load (`perf` is blocked)
    showed that the about 15 ms of each start were the loader reading the 3.8 MB
    front end field by field, checking and indexing 834 KB of source text a byte
    at a time, and collections that only marked the program being loaded; Boehm
    init (0.35 ms), libuv init (0.3 ms) and OpenSSL (initialized at the first
    TLS use) are small. The loader takes 8.3 ms now and `check
    examples/hello.agc` 17.5 ms, not 24.3, with every check of a file kept; what
    is left is mostly page faults (the loaded program is 4.6 MB of heap).
    Numbers, and what was tried, in
    [vm-benchmarks](../vm-benchmarks.md#speed-pass-vm-start-up-row-83).
  - **Outcome:** Each VM start costs less, and the test suite runs faster

- **Order:** 7.3
  - **Next work:** New features, VM-only (cont.): iteration and concurrent
    collections (phase 17, `docs/future/27-iteration-and-concurrency.md` §27):
    `Task.map` (17a, **done**, PR #316) with bounded concurrency, a per-item
    timeout and results in input order; `Channel[T]` (17b) moved earlier, to row
    7.2.1e; C builtins, so they need neither 8d nor the prelude; `try` in a
    block with a fixed `Result` type already works (`Test.test`),
    `File.each_line` (row 7.2.1h) adds the completion-value check and its help,
    and 17a added `try` in a block whose `Result[T]` is inferred (§25.9) to the
    Agentica front end, where `File.open` with a block (15i) reuses it; they
    land before phase 16, whose PRs migrate their programs; `Task.await` with a
    timeout (17c, built) is a C builtin that returns the builtin enum
    `Await[T]`, moved out of step 8.2 by the owner on 2026-10-14 (§27.3);
    `Stream[T]` (17e) comes at step 8.2 (§27.4)
  - **Outcome:** Programs run I/O for each item of a list N at a time, and build
    producer and consumer pipelines, with one form for each job; CPU speed-ups
    follow only if the multicore schedulers land (step 11)

- **Order:** 7.4
  - **Next work:** New features, VM-only (cont.): the streaming items of phase
    20 (20e to 20g,
    [§30](../future/30-hybrid-http.md#3011-streaming-on-channels), the hybrid
    HTTP plan), built on the channels of 17b; then `TlsContext` ([phase
    19](19-tls-context.md), [§29](../future/29-tls-context.md#29-tls-contexts)),
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
    decided by the owner on 2026-10-15 (phase 27,
    [`docs/roadmap/27-signals.md`](27-signals.md); design:
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
    on 2026-10-15 (phase 28, [`docs/roadmap/28-formatter.md`](28-formatter.md);
    design: [§47](../future/47-formatter.md#47-code-formatter-agentica-fmt)): a
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
    on 2026-10-15 (phase 29, [`docs/roadmap/29-regex.md`](29-regex.md); design:
    [§48](../future/48-regex.md#48-regular-expressions)): regular expressions,
    new library features, std first: `std/regex` in Agentica (a parser and a
    linear-time Pike VM, no backtracking), then the regex literal
    `/pattern/flags` (48b, `compiler/` only); a C matcher only if measured
    (48c). It comes before row 7.9 (the formatter), by the owner's decision of
    2026-10-15.
  - **Outcome:** A program searches, extracts, replaces and splits text with a
    pattern, written as a literal or a string, and no pattern can stall the VM

- **Order:** 7.11
  - **Next work:** **Planned**, not yet scheduled by the owner (phase 31,
    [`docs/roadmap/31-test-functions.md`](31-test-functions.md); design:
    [§50](../future/50-test-functions.md#50-test-functions)): a `*_test.agc`
    file may have no `main`; its top-level `test_*` functions are its tests, and
    the front end adds the `main` that runs them (50a, `compiler/` only).
    Post-bootstrap step 6.
  - **Outcome:** A test file reads as a list of tests, with no `main` and no
    `Test.test` blocks

- **Order:** 7.12
  - **Next work:** **30a implemented; 30b planned** (phase 30,
    [`docs/roadmap/30-type-aliases.md`](30-type-aliases.md); design:
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
  - **Next work:** JIT (7m, `docs/future/22-jit.md` §22): required, not gated;
    after 7l and 7j, independent of 7i and of the multicore decision, and before
    multicore (row 11), by the owner's decision of 2026-10-16. The FFI of
    [§40](../future/40-native-code.md) comes before it, by the owner's decision
    of 2026-10-15
  - **Outcome:** Hot functions run as native code with the same results

- **Order:** 11
  - **Next work:** Multicore schedulers (7h item, gated), decided with the
    numbers of step 9 (and the 6c pilot of step 7.2.2). **After the JIT (9.1)**,
    by the owner's decision of 2026-10-16 (it was right after step 9 by the
    decision of 2026-10-14); the work stops before it so the owner reviews the
    next steps. The front end is decided: self-hosting, in this table from row
    7.2.7 on ([§18](../future/18-front-end-language.md))
  - **Outcome:** Build multicore only if the numbers ask for it

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
    multicore only if the multicore schedulers land (step 11)
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
revised it on 2026-10-16: the rows that waited for the bootstrap come first,
then the path to the JIT (row 9.1, which should also speed up `agentica test`),
and the other features after the JIT.

1. **Done (2026-10-16, PR #312)**: release 0.4.0, the first release with the
   single binary ([§18.3](../future/18-front-end-language.md#183-port)).
   Racket can be deleted only after one release has the self-hosted front end
   as its default ([§18.2](../future/18-front-end-language.md#182-bootstrap)).
2. **Done (2026-10-16, PR #313)**: delete the Racket front end (`src/*.rkt`),
   freeze `vm/unicode_data.c` as checked-in source (a later PR may add a
   generator over pinned Unicode Character Database files that reproduces it
   byte for byte) and tag `bootstrap-racket` on the parent commit of the merge
   (§18.2).
3. A speed pass on the self-hosted front end: the targets of
   [§18.5](../future/18-front-end-language.md#185-goals-and-targets), the
   precompiled BDD runner (about 0.7 s that step 7b added to `agentica test`),
   and maybe a VM profiler and the start-up cut of row 8.3 (done, below).
   **First part done (2026-10-16, PR #315):** the timing rows of
   `benchmarks/run.py`, the profiler (`AGENTICA_VM_TRACE=profile`) and the BDD
   runner and default steps carried by the binary (`agentica test` of a small
   file: 0.87 s before, 0.05 s now; numbers in
   [vm-benchmarks](../vm-benchmarks.md#front-end-post-bootstrap-row-3)).
   **Second part, the lexer, done (2026-10-16, PR #317):** the lexer was
   51% of the steps of a check of the whole front end, and its steps are
   halved (`lexer.agc` 39.4 M to 19.6 M in `check compiler/front_end.agc`; the
   lexer alone 52 to 24 steps for each character), so `check
   stdlib/bdd/gherkin.agc` takes 99 ms, not 126 (measured under load). Its
   tables are module constants, which is 44b of
   [§44.12](../future/44-module-constants.md#4412-implementation-plan).
   Numbers, and what was tried, in
   [vm-benchmarks](../vm-benchmarks.md#speed-pass-second-part-the-lexer).
   **Third part, the interpreter loop, done (2026-10-16, PR #319):** the common
   value accessors are inline and the turn loop keeps the frame in locals, and
   `[]` and `{}` with no items are shared, so `arithmetic` takes 0.10 to 0.13 s,
   not 0.276 s, loops of calls and `case` 30% to 55% less, and
   `check stdlib/bdd/gherkin.agc` 0.080 s, not 0.102 s (with the new lexer).
   Numbers, a profile of where a check spends its time now, and what was
   tried, in
[vm-benchmarks](../vm-benchmarks.md#speed-pass-third-part-the-interpreter-loop).
   **VM start-up, done (2026-10-16, PR #326):** the loader of the carried
   front end took 15 ms of every start and takes 8.3 ms now (row 8.3), so a
   hello check is 17.5 ms, not 24.3, and `check stdlib/bdd/gherkin.agc` is
   about 8 ms faster. Numbers in
   [vm-benchmarks](../vm-benchmarks.md#speed-pass-vm-start-up-row-83).
   **Shared small values, done (2026-10-16,
   [§34](../future/34-shared-small-values.md)):** one empty String and one
   empty Set join the one-character Strings, the empty List and the empty Map,
   and the builtins that end with one of them return it, so a loop of `at` or
   `slice` allocates 92% fewer bytes and the new `small-values` program takes
   23% less time. Numbers, the layout noise and what was dropped in
   [vm-benchmarks](../vm-benchmarks.md#speed-pass-shared-small-values-34).
   Still to do: the parser, for room under the 100 ms for
   `stdlib/bdd/gherkin.agc`.
4. **Done (2026-10-16)**: default parameter values (row 7.5a, in the
   [grammar's default parameters][grammar-defaults]), in `compiler/`, which
   does not use them yet.
5. `case` guards, nested patterns and the `<<~NAME` heredoc
   ([`docs/grammar/05-syntax.md`](../grammar/05-syntax.md#statements-and-blocks)
   and [`04-lexical.md`](../grammar/04-lexical.md#heredocs)), in `compiler/`
   only. The first of steps 4 and 5 to land is the first use of
   the two-step stage0 refresh of §18.2. Part A, the heredoc (15j), is **done
   (2026-10-16, PR #322)**: the lexer, `LEX-UNTERMINATED-HEREDOC`,
   `LEX-HEREDOC-INDENT`, `LEX-HEREDOC-ONE-LINE`, the parser refuses a heredoc
   as a `case` pattern or an import path. Part B, `case` guards and nested
   patterns (post-bootstrap step 5, in the grammar), is **done
   (2026-10-16, PR #325)**: `pattern if condition ->` and any pattern in a
   payload position, a conservative exhaustiveness rule, no bytecode change.
   `compiler/` does not use them yet (the two-step stage0 refresh is a later
   PR).
6. The other rows that waited for the bootstrap: the prelude (row 8.2), strict
   diagnostics (row 7.6), `agentica doc` and `help` (row 22b), and the 44b to
   44d table rewrites (**done 2026-10-16**;
   [§44.12](../future/44-module-constants.md#4412-implementation-plan)), type
   aliases (row 7.12, §49: simple first, 49a, then generic, 49b), then test
   functions without `main` (row 7.11, §50). `Task.map` (row 7.3) was small
   and is **done** (17a, PR #316).
7. The path to the JIT: the rest of the VM layers (row 8.1), VM metrics (row
   7.7), the server measurement (row 9), the FFI and native module header
   ([§40](../future/40-native-code.md)), then the JIT (row 9.1). Multicore
   (row 11) comes after the JIT (owner, 2026-10-16), and the work stops before
   it for the owner's review.
8. After the JIT: multicore (row 11, above); the semantic CLI (row 7.2b,
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
   fixed order: HTTP streaming and `TlsContext` (row 7.4), UDP (row 7.5), the
   6c evaluation round (row 10) and the Unicode generator.

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

Designed, not scheduled: packages (§45,
[`docs/future/45-packages.md`](../future/45-packages.md)). It has no row in this
table. Its first step, the TOML parser `std/toml` (45-0), is a std module and
landed before the bootstrap (done). The manager waits for step 8 of §18.3.

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
  `src/stdlib.rkt`), not as builtins. Examples: numbers to bytes, bit tricks
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
     and `Float` bit conversions of `docs/future/23-binary-data.md` §23.
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
  `stdlib/` call them (`std-only-modules` in `src/builtins.rkt`), and user code
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

- **File:** [`09-ats.md`](09-ats.md)
  - **Contents:** Phase 9: shared tables (ATS)

- **File:** [`10-adapters-and-json.md`](10-adapters-and-json.md)
  - **Contents:** Phase 10: adapters and JSON inspection

- **File:** [`11-cbor.md`](11-cbor.md)
  - **Contents:** Phase 11: binary serialization (CBOR)

- **File:** [`12-benchmarks.md`](12-benchmarks.md)
  - **Contents:** Phase 12: cross-language benchmarks

- **File:** [`13-binary-data.md`](13-binary-data.md)
  - **Contents:** Phase 13: binary data

- **File:** [`14-logging.md`](14-logging.md)
  - **Contents:** Phase 14: logging and debugging

- **File:** [`15-ruby-typed-idioms.md`](15-ruby-typed-idioms.md)
  - **Contents:** Phase 15: Ruby typed idioms

- **File:** [`16-strict-diagnostics.md`](16-strict-diagnostics.md)
  - **Contents:** Phase 16: strict diagnostics (no warnings)

- **File:** [`17-iteration-and-concurrency.md`](17-iteration-and-concurrency.md)
  - **Contents:** Phase 17: iteration and concurrent collections (`Task.map`,
    channels, `Task.await` with a timeout)

- **File:** [`18-vm-metrics.md`](18-vm-metrics.md)
  - **Contents:** Phase 18: VM metrics (Prometheus)

- **File:** [`19-tls-context.md`](19-tls-context.md)
  - **Contents:** Phase 19: TLS contexts (`TlsContext`, `TLS.upgrade`)

- **File:** [`20-hybrid-http.md`](20-hybrid-http.md)
  - **Contents:** Phase 20: HTTP on the VM, simple and synchronous (C framing,
    `std/http` in Agentica), then streaming on channels

- **File:** [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md)
  - **Contents:** Phase 21: BDD in Agentica (`std/bdd`, a runner and a child VM
    per scenario; catch-up item 7h)

- **File:** [`22-doc-comments.md`](22-doc-comments.md)
  - **Contents:** Phase 22: doc comments (`##` lines, `agentica doc`, `help` for
    `std/`)

- **File:** [`23-digit-separators.md`](23-digit-separators.md)
  - **Contents:** Phase 23: digit separators in number literals (`1_000`)

- **File:** [`24-task-crash-isolation.md`](24-task-crash-isolation.md)
  - **Contents:** Phase 24: task crash isolation (a crash ends only its task)

- **File:** [`25-unit-tests.md`](25-unit-tests.md)
  - **Contents:** Phase 25: unit tests (the `Test` module, `*_test.agc` in
    `agentica test`)

- **File:** [`26-semantic-cli.md`](26-semantic-cli.md)
  - **Contents:** Phase 26: semantic CLI for agents (`agentica outline`,
    `symbol`, `refs`, `type-at`)

- **File:** [`27-signals.md`](27-signals.md)
  - **Contents:** Phase 27: signals (stop signals a program handles, signals to
    children, the driver's stop, graceful HTTP stop; design in §46)

- **File:** [`28-formatter.md`](28-formatter.md)
  - **Contents:** Phase 28: code formatter (`agentica fmt`, `--check`, the
    `[style]` keys; design in §47)

- **File:** [`29-regex.md`](29-regex.md)
  - **Contents:** Phase 29: regular expressions (`std/regex` in Agentica, then
    the regex literal; design in §48)

- **File:** [`30-type-aliases.md`](30-type-aliases.md)
  - **Contents:** Phase 30: type aliases (simple, then generic; design in §49)

- **File:** [`31-test-functions.md`](31-test-functions.md)
  - **Contents:** Phase 31: test functions without `main` (`test_*` functions
    are tests; design in §50)

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
[agentica-link-2]: ../future/36-unit-tests.md
[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
[agentica-link-4]: ../future/30-hybrid-http.md
[agentica-link-5]: pending-general-programming-and-mcp.md
[grammar-defaults]: ../grammar/06-semantics.md#default-parameter-values
[grammar-syntax-precedence]: ../grammar/05-syntax.md#expressions-and-precedence
