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

The Racket evaluator is frozen and runs only what the VM still lacks (row
7.1). The table below is the one source for the order of pending work and
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
| 7 | **Complete:** the VM is the default backend (7i, first item): `agentica file.agc` runs on the VM; programs that use `TCP`, `TLS`, `HTTP` or `BDD`, and `agentica test`, fall back to the evaluator; the differential tests became golden tests; the release ships `agentica-vm` | One backend for almost every program; CI runs each test once |
| 7.1 | **Next, catch-up:** 7h processes (done), then VM tracing (14a, `docs/future/24-logging.md` §24.4, done), then TCP (done), then TLS (today's API, done), then HTTP 20a (phase 20, `docs/future/30-hybrid-http.md` §30: hybrid and synchronous, whole messages, C for parsing, framing, the pool and the server's task group, `std/http` in Agentica, imported as `HTTP`; a breaking change; done), then BDD in Agentica ([phase 21](21-bdd-in-agentica.md), 7h, [§31](../future/31-bdd-in-agentica.md#31-bdd-in-agentica): `std/bdd` and a runner in Agentica, a child VM per scenario; it needs only 20a; done), then HTTP 20b to 20d (the builtin `HTTP` module, server included, falls back to the evaluator until 20d, so 7i cannot come earlier), then 7i; each PR removes its fallback (order decided by the user on 2026-10-13) | Every example, CI smoke test and `agentica test` runs on the VM |
| 7.2 | 7i: delete the evaluator and its runtime modules; the Racket front end (lexer, parser, checker, lowering, bytecode) stays | One backend |
| 7.2a | New features, VM-only, first: doc comments ([phase 22](22-doc-comments.md), [§32](../future/32-doc-comments.md#32-doc-comments): `##` lines, `agentica doc`, front end only), then digit separators ([phase 23](23-digit-separators.md), [§33](../future/33-digit-separators.md#33-digit-separators): `1_000`, lexer only) | Programs carry `##` docs that `agentica doc` prints, and write long numbers as `1_000_000` |
| 7.3 | New features, VM-only (cont.): iteration and concurrent collections (phase 17, `docs/future/27-iteration-and-concurrency.md` §27): `Task.map` (17a) with bounded concurrency, a per-item timeout and results in input order, then `Channel[T]` (17b), bounded with required timeouts; C builtins, so they need neither 8d nor the prelude; 17a adds the checker rule for `try` in a block whose result is `Result[T]` (§25.9), which 15i reuses; they land before phase 16, whose PRs migrate their programs; `Task.await` with a timeout (17c) is prelude code and comes at step 8.2; lazy streams stay to evaluate later (§27.4) | Programs run I/O for each item of a list N at a time, and build producer and consumer pipelines, with one form for each job; CPU speed-ups follow only if the multicore schedulers land (step 11) |
| 7.4 | New features, VM-only (cont.): the streaming items of phase 20 (20e to 20g, [§30](../future/30-hybrid-http.md#3011-streaming-on-channels), the hybrid HTTP plan), built on the channels of 17b; then `TlsContext` ([phase 19](19-tls-context.md), [§29](../future/29-tls-context.md#29-tls-contexts)) | Programs stream HTTP bodies through channels and set up TLS with a `TlsContext` |
| 7.5 | New features, VM-only (cont.): default parameter values first (15a, `docs/future/25-ruby-typed-idioms.md` §25.1; front end only, so `std/log` can use them), then binary data (phase 13, `docs/future/23-binary-data.md` §23), then UDP, then logging and debugging (14b stack traces, then 14c `std/log`, `docs/future/24-logging.md` §24), then the `Crypto` module (`docs/future/20-crypto.md` §20: hashes, HMAC, constant-time compare, random bytes, password hashing and AEAD on OpenSSL 3; needs `Bytes`) | Programs read and write binary numbers with `std/binary` and send UDP; agents see the call stack of a runtime error; programs log with levels, fields and JSON lines, and sign, hash and encrypt |
| 7.6 | New features, VM-only (cont.): strict diagnostics first (phase 16, `docs/future/26-strict-diagnostics.md` §26, no warnings: `CHECK-UNUSED-IMPORT`, `CHECK-UNUSED-VARIABLE`, `CHECK-UNREACHABLE-CODE`, `CHECK-UNUSED-RESULT`, in the order 16a, 16c, 16b, 16d; front end only, each PR migrates the repo's programs); then Ruby typed idioms (phase 15, `docs/future/25-ruby-typed-idioms.md` §25, Part A, one way to do each thing): re-exports, `with`, value equality, lambdas, `File.open` with a block, heredocs (15b to 15e, 15i, 15j); one small PR each | Unused imports, unused variables, unreachable code and ignored `Result` values are errors, and there are no warnings; agents write the Ruby forms they know, still checked, immutable and with one canonical form |
| 7.7 | VM metrics (phase 18, `docs/future/28-vm-metrics.md` §28), VM-only, no language change: 18a metrics derived from the VM's own state and the `.prom` file, 18b the `GET /metrics` endpoint, 18c the enabled-only hooks with the overhead check; it needs only 7i (not the HTTP stack), and goes before the server measurement (7j) | Prometheus scrapes a running VM and Grafana graphs its GC, tasks, run-queue delay and I/O; batch runs leave their exit code and totals for node_exporter; nothing costs anything while nobody asks |
| 8 | Faster lists (8d): a persistent vector behind `List`, before any instruction-dispatch micro-optimization (7g); then the review of what the VM inherited from Racket (7k), next to the 7g hot spots | `push` stops copying the whole list; list-heavy programs stop being O(n²); the VM keeps Racket's rules only where they are good on their own |
| 8.1 | VM layers (7l, `docs/future/21-vm-layers.md` §21); after the tasks PR, next to 7k | The prerequisites of the JIT |
| 8.2 | Ruby typed idioms, prelude part (15f, 15k; `docs/future/25-ruby-typed-idioms.md` §25.6 and §25.11): the compiler prelude with the Enumerable methods, then `format`; after faster lists (8d), since the prelude's cost contract needs them; then `Task.await` with a timeout (17c, `docs/future/27-iteration-and-concurrency.md` §27.3), prelude code over the channels of 17b | Enumerable methods, `format` and `Task.await(task, timeout_ms)`, written in Agentica, O(n) on the new lists |
| 9 | Server measurement on the VM (7j), with the source → result runner (7g); it also reads the VM metrics of phase 18 (GC, run-queue delay, I/O) while the load runs | Requests/s, p50/p99 latency (also while a CPU-bound task runs), peak memory and real start-up, against Python as an outside reference |
| 9.1 | JIT (7m, `docs/future/22-jit.md` §22): required, not gated; after 7l and 7j, independent of 7i and of the multicore decision | Hot functions run as native code with the same results |
| 10 | Evaluation round: Agentica against typed Python on harder tasks (6c) | Evidence on whether agents do better in Agentica than in typed Python |
| 11 | Decide with the results of steps 9 and 10: multicore schedulers (7h item, gated) and a front-end rewrite (`docs/future/18-front-end-language.md` §18, gated) | Build multicore or a new front end only if the numbers ask for it |
| 12 | Core data structures (phase 8): `Set[T]` and `Queue[T]` (may proceed in parallel with steps 6 to 11) | Write loops and algorithms the Ruby way, without workarounds |
| 13 | Real applications | Validate the APIs with a file-processing CLI, automation script and HTTP service |
| 14 | Cross-language benchmarks (phase 12): the same small programs in Agentica (VM), Ruby, Crystal and optionally Python. Round 1 (single-threaded; needs the 7g benchmark script (done), the real applications, faster lists (8d) and the VM `IO` library (`docs/vm/12-testing-and-pr-plan.md` §12.2 item 6a, done)) goes before MCP; round 2 (concurrent programs) needs tasks on the VM (7h) and covers multicore only if the multicore schedulers land (step 11) | Honest speed numbers against Ruby and Crystal, and the VM hot spots to fix next |
| 15 | MCP examples (5m), then Streamable HTTP | Build protocol clients and servers on the proven foundations |
| 16 | Adapters and JSON inspection (phase 10 goes before phase 9): call `Fn` fields without `.call`, `JSON.kind`, generic structs, JSON for enums, optional and nullable JSON fields | Write adapters and read JSON of unknown shape without workarounds |
| 17 | (On demand) Shared tables (phase 9): `Table[K, V]`; needs tasks on the VM (7h); starts when a real program needs it | Share a cache or a counter that tasks update |
| 18 | (On demand) Binary serialization (phase 11): typed `Term.encode`/`Term.decode` in CBOR; needs `Bytes`, generic structs (10c) and the JSON form of enums (10d); starts when a real program needs it | Keep a disk cache or send values between Agentica processes without losing Int keys, Float bits or enums |
| 19 | (On demand) SIMD in the VM (`docs/future/19-simd.md` §19): AVX2 first, with run-time dispatch and a scalar fallback; only after profiling (7j or phase 12) shows time in string, JSON or copy routines | Faster string and JSON work without changing the release baseline |

After steps 1–2, target everyday scripts and automation. After steps 13 and 15
(real applications and MCP), target larger general-purpose programs.
Keep diagnostics, behavior tests, grammar, and the self-contained programming
reference part of every phase.
Specify new APIs in `docs/future/` before implementation; move them into the
grammar only when they land. Detailed pending work appears after the completed
foundations below.

### Rules for the catch-up and new features

- Catch-up work is tested with golden outputs and independent Node/Python
  peers, not against the evaluator. A catch-up PR (TCP, TLS, HTTP, BDD on the
  VM) removes the fallback for its module.
- New features are VM-only and come after 7i. They have no Racket twin.
  One exception, decided by the user on 2026-10-12: the HTTP catch-up
  (phase 20, 20a to 20d) changes the HTTP API before 7i (whole messages,
  `std/http` behind an import, the std-only `HttpWire` builtins) instead of
  porting today's API, and the driver refuses (`LOWER-UNSUPPORTED`, "needs
  the VM") any program that needs those VM-only builtins on an evaluator
  path, as [phase 21](21-bdd-in-agentica.md) does for its own builtins.
- The evaluator is frozen: it gets no new behaviour, only the fixes that keep
  the fallback running until 7i deletes it.

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
  `docs/future/30-hybrid-http.md` §30.5), the framing layer under
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
| [`pending-general-programming-and-mcp.md`](pending-general-programming-and-mcp.md) | Pending work: general programming and MCP (everyday library, typed JSON, modules, real applications, MCP) |
| [`ruby-style-ergonomics.md`](ruby-style-ergonomics.md) | Ruby-style ergonomics (complete) |
| [`later-extensions.md`](later-extensions.md) | Later extensions and open decisions |
| [`done.md`](done.md) | Completed phases 1 to 5h and the completed foundations (5j, BDD features, 5j2, 5k, 5n) |

Planned syntax is in [`docs/future/`](../future/README.md).
