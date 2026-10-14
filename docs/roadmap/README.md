# Agentica implementation roadmap

This roadmap turns the core specification in [`grammar.md`](../grammar.md) into a usable interpreter. Planned syntax lives in [`docs/future/`](../future/README.md) until its phase lands. Keep every phase focused on the core in sections 4–6 until the prototype can run and diagnose the examples in sections 7–8. Enums were kept out of the initial milestone and are now implemented as a later extension.

## Current implementation order

The core interpreter, Results, JSON primitives, function values, lightweight
tasks, BDD, TCP/TLS/HTTP, files/paths, strict Void, processes, modules and the
Ruby-style ergonomics are implemented. The bytecode VM is the default backend:
`agentica file.agc` compiles in-process and runs `agentica-vm`. The design
(7b), lowering, bytecode and the VM (`docs/vm/12-testing-and-pr-plan.md` §12.2
items 1 to 10), the 7g benchmark script, and 7h part 1 (event loop and files),
tasks and processes are done, with small items still open in 7c
(`tests/lower-test.rkt`), 7e (loader validation for opcodes as they land) and
7f (the extra corpora). Ranges (8a) are done.

The VM is the only backend: 7i deleted the Racket evaluator (row 7.2). The
table below is the one source for the order of pending work and
its dependencies; each row names its phases and the sections that specify
them. Historical phase numbers remain stable; this order governs pending
work rather than their numeric order.

| Order | Next work | Outcome |
|---|---|---|
| 1 | **Complete:** Everyday library (remaining 5n plus strings, conversions, time and randomness) | Write useful scripts without rebuilding basic helpers |
| 2 | **Complete:** Typed JSON (5f2) and builders/schemas (5i) | Handle structured input and construct replies |
| 3 | **Complete:** Modules and imports, including embedded `std/` and external `pkg/` resolution | Split larger programs across files |
| 4 | **Complete:** Ruby-style ergonomics: operators, methods on builtins, interpolation, blocks and closures, `break`/`next`, printing any value with `to_s`, and the forms agents use (measured in evaluation rounds 5–8) | Accept the Ruby habits agents already have, with static types |
| 5 | **Mostly complete:** Bytecode VM core in C with the Boehm GC (`docs/vm/12-testing-and-pr-plan.md` §12.2 items 1 to 8), the 7g benchmark script, 7h part 1 (event loop and files) and ranges (8a); small items stay open in 7c, 7e (loader validation for opcodes as they land) and 7f | Checked programs run on the VM with the evaluator's exit code, stdout, program stderr and diagnostic codes, now recorded as golden outputs |
| 6 | **Complete:** 7h tasks with one scheduler (N=1) on the structures split for N (`docs/vm/10-io-multicore.md` §10.2.3), with the fairness rule of §10.2.1 (long builtins charge the turn, never `--max-steps`) and the latency test of the 7h tasks item | Concurrent programs on the VM; timers and I/O stay responsive while other tasks compute |
| 7 | **Complete:** the VM is the default backend (7i, first item): `agentica file.agc` runs on the VM; programs that use `TCP`, `TLS`, `HTTP` or `BDD`, and `agentica test`, fell back to the evaluator at first (each 7.1 PR removed its fallback, and 7i removed the last one, `HTTP`); the differential tests became golden tests; the release ships `agentica-vm` | One backend for almost every program; CI runs each test once |
| 7.1 | **Complete, catch-up:** 7h processes, then VM tracing (14a, `docs/future/24-logging.md` §24.4), then TCP, then TLS (today's API), then HTTP 20a (phase 20, `docs/vm/10-io-http.md` §10.7: hybrid and synchronous, whole messages, C for parsing, framing and the pool, `std/http` in Agentica, imported as `HTTP`), then BDD in Agentica ([phase 21](21-bdd-in-agentica.md), 7h, [`docs/bdd.md`](../bdd.md): `std/bdd` and a runner in Agentica, a child VM per scenario); each PR removed its fallback | Every example, CI smoke test and `agentica test` runs on the VM |
| 7.2 | **Complete:** 7i: delete the evaluator and its runtime modules; the Racket front end (lexer, parser, checker, lowering, bytecode) stays. Decided by the owner on 2026-10-13: 7i came before HTTP 20b to 20d and deleted the builtin `HTTP` module with the evaluator (its last fallback user), so `HTTP` is the free import alias of `std/http` and programs keep its client; HTTP 20c then brought back a server (`std/http`, `examples/http_server.agc`) | One backend |
| 7.2.1 | **Complete:** HTTP 20b (the task cancellation core, done), then task crash isolation ([phase 24](24-task-crash-isolation.md), [§37](../future/37-task-crash-isolation.md#37-task-crash-isolation): a crash in a task other than `main` ends only that task; it needs 20b; done), then unit tests ([phase 25](25-unit-tests.md), [§36](../future/36-unit-tests.md#36-unit-tests-test): the builtin `Test` module and `*_test.agc` files in `agentica test`; after phase 24, so a crash fails one test; done), then HTTP 20c (done: the `std/http` server, which brings back an HTTP server and `examples/http_server.agc`, and also takes what was left of 20d, since 7i did the switch; it does not depend on phases 24 and 25 and could go before them; [phase 20](20-hybrid-http.md)); VM-only. The owner set this order on 2026-10-13: 7i, then HTTP 20b, then [phase 24](24-task-crash-isolation.md), then [phase 25](25-unit-tests.md), then 20c, then doc comments (phase 22) and digit separators (phase 23); the 6c pilot (row 7.2.2, decided by the owner the same day) now comes between 20c and doc comments, after the VM layers of row 7.2.1b and the core simplification of row 7.2.1a | Programs serve HTTP again, with handlers that return a whole response; a crash in a task ends only that task; `agentica test` runs unit tests next to the features |
| 7.2.1c | **Complete:** VM architecture note ([§16](../vm/16-architecture.md#16-vm-architecture)), decided by the owner on 2026-10-13, docs only: N schedulers that pull from one global run queue, one I/O thread (the main thread) with the only libuv loop, the libuv pool for bounded blocking work, intrusive queues with one mutex each, and how a task parks and wakes. [§10.2.3](../vm/10-io-multicore.md) now keeps the rules per thread. More than one scheduler stays gated (step 11). The owner set this order after HTTP 20c: this note, then row 7.2.1b, then rows 7.2.1d, 7.2.1e and 7.2.1f, then row 7.2.1a, then the pilot (row 7.2.2). The table order below is that order | One picture of the threads, the queues and who owns what, before code is written on top of it |
| 7.2.1b | **Complete:** VM layers, the first part of [7l](07-vm.md#7l-vm-layers), planned by the owner on 2026-10-13, VM-only, no behavior change ([§15](../vm/15-layers.md#15-vm-layers)): three layers with one-way dependencies (core, services, adapters) and a driver that wires them, one small port between the services and the core (park a task, submit a job with its timeout, register and close a handle; the functions that exist today), `vm/agc.h` split into `value.h`, `port.h`, `core.h` and `services.h`, and a CI check (`vm/tools/check-layers.sh`, run by `make vm-layers`) with the include rules (`rg`: a core file includes no service header, a service includes no `core.h`, a third-party header stays in its file) and the link rules (`nm`: no core object uses a service or adapter symbol, an adapter uses only the memory functions of the core). Two small mechanical PRs, both done: the moves, then the headers and the check. It waited for HTTP 20c and for the blocked-read fix of row 7.2.1a (both change `input.c`, `files.c` and the HTTP services; both are done). It comes before 25c and 24b of row 7.2.1a: 25c adds process builtins and 24b changes handle ownership, so both should be written on the port. The rest of 7l (opcode helpers, builtin metadata flags, the callback-builtin protocol) stays at row 8.1 | The core never calls a service by name, and CI keeps it so; 25c and 24b are written on a named port |
| 7.2.1d | **Complete (asynchronous process close, then the flush limit):** small PRs, VM-only, decided by the owner on 2026-10-13: asynchronous process close and an always-on file-flush limit ([§14.1](../vm/14-core-invariants.md#141-waiting), [§14.4](../vm/14-core-invariants.md#144-ending)). libuv's exit callback reaps the child; `Process.close` parks the calling task on a job with a timer; a close during a crash is fire-and-forget; this removes the 1 s `nanosleep` reap on the loop thread. The file flush gets a limit that is always on: 30 seconds by default, set with `--flush-timeout MS` or an environment variable (for example `AGENTICA_FLUSH_TIMEOUT_MS`), with no way to turn it off; this replaces the earlier choice of phase 24 (no limit by default). After the VM layers (row 7.2.1b) | `Process.close` never blocks the loop thread, and the end of a run is always bounded |
| 7.2.1e | `Channel[T]` (17b, [§27.2](../future/27-iteration-and-concurrency.md#272-channels)), moved earlier by the owner on 2026-10-13: the spec first (docs only, done), then the implementation, because stdout and stderr (row 7.2.1f) build on its parking mechanism. 17a (`Task.map`) stays at row 7.3; the tests that need `Task.map` move to 17a's PR ([phase 17](17-iteration-and-concurrency.md)) | Producer and consumer pipelines with one form, and a parking mechanism for bounded buffers |
| 7.2.1g | **Complete:** Pipe operator `\|>` (15l, [§25.14](../future/25-ruby-typed-idioms.md#2514-pipe-operator-)), decided by the owner on 2026-10-14: a small front-end PR (lexer, parser, one checker rule; no VM change) after channels (row 7.2.1e) and before stdout and stderr on the loop (row 7.2.1f). The owner chose it over methods on structs or Lua-style metatables, which stay decided against ([§25.13](../future/25-ruby-typed-idioms.md#2513-decided-against-part-c)) | User functions chain left to right, with one form per call |
| 7.2.1f | stdout and stderr on the loop, decided by the owner on 2026-10-13, VM-only: `puts`, `print`, `IO.inspect` and `IO.warn` stop being blocking writes ([§14.1](../vm/14-core-invariants.md#141-waiting)) and park the task on the parking mechanism of channels (row 7.2.1e). Until then they stay blocking writes. One 64 KiB buffer and a FIFO of writers per stream, the I/O thread is the only writer, `/proc/self/fd` reopen as for stdin; spec in [§10.2.2](../vm/10-io-scheduler.md#1022-the-loop) | A full stdout pipe no longer stalls every task |
| 7.2.1a | Core simplification, decided by the owner on 2026-10-13, VM-only, held to the [VM core invariants](../vm/14-core-invariants.md#14-vm-core-invariants) (§14). Outside the order and free to land at any time, being a bug fix: a separate fix PR for blocked reads at exit (**done**, PRs #162 and #164: §14.4 one exit path and stop signals; §14.1 stdin, FIFOs and character devices read non-blocking on the loop, not in the pool). Then, after the VM layers (row 7.2.1b) and rows 7.2.1d to 7.2.1f (the owner's order of 2026-10-13), and before the pilot, two small PRs: first the child protocol on its own channel ([25c](25-unit-tests.md), [§36.6](../future/36-unit-tests.md#366-isolation-a-child-vm-per-file-a-task-per-test)): `Process.spawn_captured` gains an optional extra pipe (fd 3 and an environment marker) with a small child-side builtin pair to read and write it, unit-test and BDD children (scenario and list modes) use it, and the VM drops 25b's token, reserved stdin, private fd 0 and `out_mid_line`; then one handle-ownership rule ([24b](24-task-crash-isolation.md), [§37.5](../future/37-task-crash-isolation.md#375-handles-of-a-crashed-task), §14.5): a handle belongs to the task that opened it, is closed when that task ends, and moves to another task only explicitly, replacing three mechanisms (the spawn move, `agc_give_owned` and 20c's `HttpWire.spawn` group registration, which becomes a use of the explicit form); it needs 20c | Tests read their own stdin and print freely; one rule for who closes a handle; a smaller core before it is measured and built on |
| 7.2.2 | Evaluation pilot, after rows 7.2.1, 7.2.1b, 7.2.1d, 7.2.1e, 7.2.1f and 7.2.1a (decided by the owner on 2026-10-13; [phase 6c](06-validation.md#phase-6c-agentica-against-typed-python)): first a regression round of the `binary` arm on the VM, with the two models and tasks of rounds 6 (DeepSeek) and 8 (GLM 5.3 flash), t1–t8, 3 reps per task, compared with those rounds in `docs/eval.md`; then a first 6c pilot: about 20 tasks (the 8 of today plus about 12 of the harder kinds of 6c, each with hidden tests and reference solutions in Agentica and typed Python), the same agent, two models (those of rounds 6 and 8) and budget for the Agentica `skill` arm and a typed Python arm, 3 reps per cell; it measures functional success, tokens, attempts, compile and check errors and time to a correct solution. It needs the 6c typed Python arm and the pilot's tasks first (the first two items of 6c). Its results decide the order of the rows that follow; the full 6c round, with enough reps for its claims, stays at step 10 | Evidence that the VM-only language did not regress for agents, and a first answer on Agentica against typed Python, early enough to change the plan |
| 7.2a | New features, VM-only, after rows 7.2.1 and 7.2.2: doc comments ([phase 22](22-doc-comments.md), [§32](../future/32-doc-comments.md#32-doc-comments): `##` lines, `agentica doc`, front end only), then digit separators ([phase 23](23-digit-separators.md), [§33](../future/33-digit-separators.md#33-digit-separators): `1_000`, lexer only) | Programs carry `##` docs that `agentica doc` prints, and write long numbers as `1_000_000` |
| 7.2b | New features, VM-only (cont.), after row 7.2a: the semantic CLI for agents ([phase 26](26-semantic-cli.md), [§39](../future/39-semantic-cli.md#39-semantic-cli-for-agents)): `agentica outline`, then `agentica symbol` and `agentica refs`, then `agentica type-at`, JSON first; front end and CLI only, nothing to run, no LSP; the full 6c round (step 10) measures it | Agents list declarations, find definitions and references across modules, and get the checked type at a position, without reading whole files or guessing from `rg` |
| 7.3 | New features, VM-only (cont.): iteration and concurrent collections (phase 17, `docs/future/27-iteration-and-concurrency.md` §27): `Task.map` (17a) with bounded concurrency, a per-item timeout and results in input order; `Channel[T]` (17b) moved earlier, to row 7.2.1e; C builtins, so they need neither 8d nor the prelude; 17a adds the checker rule for `try` in a block whose result is `Result[T]` (§25.9), which 15i reuses; they land before phase 16, whose PRs migrate their programs; `Task.await` with a timeout (17c) is prelude code and comes at step 8.2; lazy streams stay to evaluate later (§27.4) | Programs run I/O for each item of a list N at a time, and build producer and consumer pipelines, with one form for each job; CPU speed-ups follow only if the multicore schedulers land (step 11) |
| 7.4 | New features, VM-only (cont.): the streaming items of phase 20 (20e to 20g, [§30](../future/30-hybrid-http.md#3011-streaming-on-channels), the hybrid HTTP plan), built on the channels of 17b; then `TlsContext` ([phase 19](19-tls-context.md), [§29](../future/29-tls-context.md#29-tls-contexts)) | Programs stream HTTP bodies through channels and set up TLS with a `TlsContext` |
| 7.5 | New features, VM-only (cont.): default parameter values first (15a, `docs/future/25-ruby-typed-idioms.md` §25.1; front end only, so `std/log` can use them), then binary data (phase 13, `docs/future/23-binary-data.md` §23), then UDP, then logging and debugging (14b stack traces, then 14c `std/log`, `docs/future/24-logging.md` §24), then the `Crypto` module (`docs/future/20-crypto.md` §20: hashes, HMAC, constant-time compare, random bytes, password hashing and AEAD on OpenSSL 3; needs `Bytes`) | Programs read and write binary numbers with `std/binary` and send UDP; agents see the call stack of a runtime error; programs log with levels, fields and JSON lines, and sign, hash and encrypt |
| 7.6 | New features, VM-only (cont.): strict diagnostics first (phase 16, `docs/future/26-strict-diagnostics.md` §26, no warnings: `CHECK-UNUSED-IMPORT`, `CHECK-UNUSED-VARIABLE`, `CHECK-UNREACHABLE-CODE`, `CHECK-UNUSED-RESULT`, in the order 16a, 16c, 16b, 16d; front end only, each PR migrates the repo's programs); then Ruby typed idioms (phase 15, `docs/future/25-ruby-typed-idioms.md` §25, Part A, one way to do each thing): re-exports, `with`, value equality, lambdas, `File.open` with a block, heredocs (15b to 15e, 15i, 15j); one small PR each | Unused imports, unused variables, unreachable code and ignored `Result` values are errors, and there are no warnings; agents write the Ruby forms they know, still checked, immutable and with one canonical form |
| 7.7 | VM metrics (phase 18, `docs/future/28-vm-metrics.md` §28), VM-only, no language change: 18a metrics derived from the VM's own state and the `.prom` file, 18b the `GET /metrics` endpoint, 18c the enabled-only hooks with the overhead check, then 18d memory diagnosis ([§28.12](../future/28-vm-metrics.md#2812-memory-diagnosis-18d): per-task allocation counters, which need channels (17b) done and, for handle bytes, the one-owner rule of 24b; and an on-demand dump of the top tasks); it needs only 7i (not the HTTP stack), and goes before the server measurement (7j) | Prometheus scrapes a running VM and Grafana graphs its GC, tasks, run-queue delay and I/O; batch runs leave their exit code and totals for node_exporter; nothing costs anything while nobody asks |
| 8 | Faster lists (8d): a persistent vector behind `List`, before any instruction-dispatch micro-optimization (7g); then the review of what the VM inherited from Racket (7k), next to the 7g hot spots | `push` stops copying the whole list; list-heavy programs stop being O(n²); the VM keeps Racket's rules only where they are good on their own |
| 8.1 | The rest of the VM layers (7l, `docs/future/21-vm-layers.md` §21: opcode helpers, builtin metadata flags, the callback-builtin protocol; the header split is row 7.2.1b); after the tasks PR, next to 7k | The prerequisites of the JIT |
| 8.2 | Ruby typed idioms, prelude part (15f, 15k; `docs/future/25-ruby-typed-idioms.md` §25.6 and §25.11): the compiler prelude with the Enumerable methods, then `format`; after faster lists (8d), since the prelude's cost contract needs them; then `Task.await` with a timeout (17c, `docs/future/27-iteration-and-concurrency.md` §27.3), prelude code over the channels of 17b | Enumerable methods, `format` and `Task.await(task, timeout_ms)`, written in Agentica, O(n) on the new lists |
| 8.3 | VM start-up cost, a small perf item ([7g](07-vm.md#7g-speed-check)): measure the about 6 ms of each VM start with `perf` and cut it. Tests start the VM thousands of times. Candidates: Boehm init, libuv init, eager OpenSSL init, bytecode verify. Before the server measurement (step 9), so its start-up numbers see the cut | Each VM start costs less, and the test suite runs faster |
| 9 | Server measurement on the VM (7j), with the source → result runner (7g); it also reads the VM metrics of phase 18 (GC, run-queue delay, I/O) while the load runs | Requests/s, p50/p99 latency (also while a CPU-bound task runs), peak memory and real start-up, against Python as an outside reference |
| 9.1 | JIT (7m, `docs/future/22-jit.md` §22): required, not gated; after 7l and 7j, independent of 7i and of the multicore decision | Hot functions run as native code with the same results |
| 10 | Evaluation round: Agentica against typed Python on harder tasks (6c), the full round after the pilot of step 7.2.2, with the semantic CLI of phase 26 (§39.12) | Evidence on whether agents do better in Agentica than in typed Python |
| 11 | Decide with the results of steps 9 and 10 (and the 6c pilot of step 7.2.2): multicore schedulers (7h item, gated). The front end is decided: self-hosting, long-term, after this table ([§35](../future/35-self-hosting.md)) | Build multicore only if the numbers ask for it |
| 12 | Core data structures (phase 8): `Set[T]` and `Queue[T]` (may proceed in parallel with steps 6 to 11) | Write loops and algorithms the Ruby way, without workarounds |
| 13 | Real applications | Validate the APIs with a file-processing CLI, automation script and HTTP service |
| 14 | Cross-language benchmarks (phase 12): the same small programs in Agentica (VM), Ruby, Crystal and optionally Python. Round 1 (single-threaded; needs the 7g benchmark script (done), the real applications, faster lists (8d) and the VM `IO` library (`docs/vm/12-testing-and-pr-plan.md` §12.2 item 6a, done)) goes before MCP; round 2 (concurrent programs) needs tasks on the VM (7h) and covers multicore only if the multicore schedulers land (step 11) | Honest speed numbers against Ruby and Crystal, and the VM hot spots to fix next |
| 15 | MCP examples (5m), then Streamable HTTP | Build protocol clients and servers on the proven foundations |
| 16 | Adapters and JSON inspection (phase 10 goes before phase 9): call `Fn` fields without `.call`, `JSON.kind`, generic structs, JSON for enums, optional and nullable JSON fields | Write adapters and read JSON of unknown shape without workarounds |
| 17 | (On demand) Shared tables (phase 9): `Table[K, V]`; needs tasks on the VM (7h); starts when a real program needs it | Share a cache or a counter that tasks update |
| 18 | (On demand) Binary serialization (phase 11): typed `Term.encode`/`Term.decode` in CBOR; needs `Bytes`, generic structs (10c) and the JSON form of enums (10d); starts when a real program needs it | Keep a disk cache or send values between Agentica processes without losing Int keys, Float bits or enums |
| 19 | (On demand) SIMD in the VM (`docs/future/19-simd.md` §19): AVX2 first, with run-time dispatch and a scalar fallback; only after profiling (7j or phase 12) shows time in string, JSON or copy routines | Faster string and JSON work without changing the release baseline |

Long-term, after the order above: the self-hosted front end and a single binary ([§35](../future/35-self-hosting.md)), decided by the owner on 2026-10-13. It gets phase numbers when it is scheduled.

After steps 1–2, target everyday scripts and automation. After steps 13 and 15
(real applications and MCP), target larger general-purpose programs.
Keep diagnostics, behavior tests, grammar, and the self-contained programming
reference part of every phase.
Specify new APIs in `docs/future/` before implementation; move them into the
grammar only when they land. Detailed pending work appears after the completed
foundations below.

### Rules for the catch-up and new features

- Work is tested with golden outputs and independent Node/Python peers. The
  catch-up (TCP, TLS, HTTP 20a, BDD on the VM) removed each fallback, and 7i
  deleted the evaluator.
- New features are VM-only. They have no Racket twin.
- A PR that changes the VM core keeps the [VM core invariants](../vm/14-core-invariants.md#14-vm-core-invariants) (§14), or changes them first with the reason.

Historical phase sections retain their original completion signatures. The
current language uses Void for completion and Nil for data; grammar.md and
the programming reference contain the current signatures.

### New library features: `std/` first

- New library features that are pure computation over types that already
  exist start as `std/` modules written in Agentica (`stdlib/*.agc`,
  registered in `src/stdlib.rkt`), not as builtins. Examples: numbers to
  bytes, bit tricks built on the `Int` builtins, text formatting, algorithms.
  They run on the VM with no VM work, and the golden fixtures test them.
- A function moves to a C builtin later only when a measurement shows it is
  hot (`make bench`, the server measurement 7j, or phase 12). Its `std/` API
  does not change, results and error strings included, so user code does not
  change; only step counts may. The new builtin is public (no internal helper
  builtins, `docs/vm/03-ir-and-bytecode.md` §4.5). It goes in an existing builtin module whose
  first parameter type fits (for example `List.read_u32_be(data, offset)`),
  never under a module named like the `std/` module's documented import
  alias, so the import keeps working. It is documented like any other
  builtin, and the `std/` function becomes a one-line wrapper.
- Exceptions, which are builtins from day one, in C only:
  1. Anything that touches the OS: files, stdin and stdout, processes,
     sockets, TLS, time, signals, random bytes from the OS. A program cannot
     make system calls.
  2. Crypto: always through the TLS/crypto provider adapter (OpenSSL 3
     today, `docs/future/20-crypto.md` §20), never hand-written in Agentica: a constant-time
     compare is impossible in an interpreter, and home-made crypto is a
     classic source of bugs.
  3. Parsers of untrusted input that have mature libraries: JSON on yyjson
     and HTTP on picohttpparser stay as decided.
  4. Anything that needs its own memory layout in the runtime: `Bytes`, and
     the insides of `Map` and `List`.
  5. Basic operations on the core types, at the level of operators, which
     would be loops or fragile code in Agentica: for example the `Int` bit
     operations and `Float` bit conversions of `docs/future/23-binary-data.md` §23.
- Library code that must be generic over the builtin type variables, or
  that must be called as a method on a builtin type (`xs.find do ... end`),
  cannot be a `std/` module; it goes in the compiler prelude
  (`stdlib/prelude/*.agc`, `docs/future/25-ruby-typed-idioms.md` §25.6), still written in Agentica.
  The prelude has guarded exceptions to "no internal helper
  builtins": `__fail_arg` and `__float_fixed` (§25.6, §25.11), and
  `__task_settled?` and `__task_wait`
  (`docs/future/27-iteration-and-concurrency.md` §27.3), which the loader
  accepts only in prelude functions.
- One builtin module is std-only: `HttpWire` (phase 20,
  `docs/vm/10-io-http.md` §10.7), the framing layer under
  `std/http`. A public raw layer next to `std/http` would be a second way
  to do HTTP, so the linker lets only modules embedded from `stdlib/`
  call it (`std-only-modules` in `src/builtins.rkt`), and user code gets
  `CHECK-UNKNOWN-NAME` with a help that shows the `std/http` import.
- Not retroactive: existing builtins, JSON included, stay as they are.


## Files

This file holds what matters now: the order above and the general rules. Each open or partly open part of the plan has its own file. Phase numbers stay as they were, so "phase 13" is in `13-binary-data.md` and "7h" is in `07-vm.md`.

| File | Contents |
|---|---|
| [`06-validation.md`](06-validation.md) | Phase 6: validate the language design, with 6c (Agentica against typed Python) |
| [`07-vm.md`](07-vm.md) | Phase 7: bytecode VM (7a to 7m; the design is in [`docs/vm/`](../vm/README.md)) |
| [`08-data-structures.md`](08-data-structures.md) | Phase 8: core data structures |
| [`09-ats.md`](09-ats.md) | Phase 9: shared tables (ATS) |
| [`10-adapters-and-json.md`](10-adapters-and-json.md) | Phase 10: adapters and JSON inspection |
| [`11-cbor.md`](11-cbor.md) | Phase 11: binary serialization (CBOR) |
| [`12-benchmarks.md`](12-benchmarks.md) | Phase 12: cross-language benchmarks |
| [`13-binary-data.md`](13-binary-data.md) | Phase 13: binary data |
| [`14-logging.md`](14-logging.md) | Phase 14: logging and debugging |
| [`15-ruby-typed-idioms.md`](15-ruby-typed-idioms.md) | Phase 15: Ruby typed idioms |
| [`16-strict-diagnostics.md`](16-strict-diagnostics.md) | Phase 16: strict diagnostics (no warnings) |
| [`17-iteration-and-concurrency.md`](17-iteration-and-concurrency.md) | Phase 17: iteration and concurrent collections (`Task.map`, channels, `Task.await` with a timeout) |
| [`18-vm-metrics.md`](18-vm-metrics.md) | Phase 18: VM metrics (Prometheus) |
| [`19-tls-context.md`](19-tls-context.md) | Phase 19: TLS contexts (`TlsContext`, `TLS.upgrade`) |
| [`20-hybrid-http.md`](20-hybrid-http.md) | Phase 20: HTTP on the VM, simple and synchronous (C framing, `std/http` in Agentica), then streaming on channels |
| [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md) | Phase 21: BDD in Agentica (`std/bdd`, a runner and a child VM per scenario; catch-up item 7h) |
| [`22-doc-comments.md`](22-doc-comments.md) | Phase 22: doc comments (`##` lines, `agentica doc`, `help` for `std/`) |
| [`23-digit-separators.md`](23-digit-separators.md) | Phase 23: digit separators in number literals (`1_000`) |
| [`24-task-crash-isolation.md`](24-task-crash-isolation.md) | Phase 24: task crash isolation (a crash ends only its task) |
| [`25-unit-tests.md`](25-unit-tests.md) | Phase 25: unit tests (the `Test` module, `*_test.agc` in `agentica test`) |
| [`26-semantic-cli.md`](26-semantic-cli.md) | Phase 26: semantic CLI for agents (`agentica outline`, `symbol`, `refs`, `type-at`) |
| [`pending-general-programming-and-mcp.md`](pending-general-programming-and-mcp.md) | Pending work: general programming and MCP (everyday library, typed JSON, modules, real applications, MCP) |
| [`ruby-style-ergonomics.md`](ruby-style-ergonomics.md) | Ruby-style ergonomics (complete) |
| [`later-extensions.md`](later-extensions.md) | Later extensions and open decisions |
| [`01-foundations.md`](01-foundations.md) | Completed phases 1 to 5n: the front end, the standard library before validation, and the completed foundations (5j, BDD features, 5j2, 5k, 5n); the open 5d3 and 6a items |

Planned syntax is in [`docs/future/`](../future/README.md).
