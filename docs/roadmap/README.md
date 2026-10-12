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

The Racket evaluator is frozen. It runs only what the VM lacks: programs that
use `TCP`, `TLS`, `HTTP` or `BDD` (the CLI falls back to it with a one-line
notice) and `agentica test`. The next work is the catch-up that removes those
fallbacks: VM tracing (14a), then TCP and TLS, then HTTP, then BDD on the VM
(7h). Then 7i deletes the evaluator. New features (binary data, UDP, logging,
crypto, then the Ruby typed idioms of phase 15) come after 7i and are
VM-only; the prelude part of phase 15 waits for faster lists (8d). The later
steps keep their order: faster lists (8d) before any instruction-dispatch
micro-optimization (7g); the review of what the VM inherited from Racket (7k)
and the VM layers (7l); a measurement of a small real server on the VM (7j)
and the JIT (7m); an evaluation round against typed Python on harder tasks
(6c); and then the decisions on the multicore schedulers (fully designed in
`docs/vm/10-io-multicore.md` §10.2.3, and gated on that measurement) and on a
front-end rewrite (`docs/future/18-front-end-language.md` §18, gated the same
way).

Sets and queues (8b, 8c) are unblocked (the VM has maps and closures) and can
proceed in parallel with the steps above. Real applications follow, then round
1 of the cross-language benchmarks (phase 12). Round 1 needs the 7g benchmark
script (done), the real applications, faster lists (8d) and the VM `IO`
library (`docs/vm/12-testing-and-pr-plan.md` §12.2 item 6a, done); round 2 needs tasks on the VM
(7h) and covers multicore only if it lands. Then MCP. Adapters and JSON inspection (phase 10) come after MCP:
they are small language items, so they go before shared tables, which wait
for a real program. 10a needs `.call` on the VM (7e PR 5e, done); 10b, 10d and
10e, and the JSON part of 10c, need the VM JSON PR (`docs/vm/12-testing-and-pr-plan.md` §12.2 item 7,
done); 10e also needs 10b. Phase 10 checks the VM and the disk backend with two
separate programs (see its "Done when"). Shared tables (phase 9) are on demand:
they need tasks on the VM (7h) and start only when a real program needs them.
Binary serialization (phase 11) is on demand too: it needs `Bytes`, generic
structs (10c) and the JSON form of enums (10d). Real applications and MCP run on
the VM, and their findings feed the VM's golden tests. Historical phase numbers below
remain stable; this order governs pending work rather than their numeric
order.

| Order | Next work | Outcome |
|---|---|---|
| 1 | **Complete:** Everyday library (remaining 5n plus strings, conversions, time and randomness) | Write useful scripts without rebuilding basic helpers |
| 2 | **Complete:** Typed JSON (5f2) and builders/schemas (5i) | Handle structured input and construct replies |
| 3 | **Complete:** Modules and imports, including embedded `std/` and external `pkg/` resolution | Split larger programs across files |
| 4 | **Complete:** Ruby-style ergonomics: operators, methods on builtins, interpolation, blocks and closures, `break`/`next`, printing any value with `to_s`, and the forms agents use (measured in evaluation rounds 5–8) | Accept the Ruby habits agents already have, with static types |
| 5 | **Mostly complete:** Bytecode VM core in C with the Boehm GC (`docs/vm/12-testing-and-pr-plan.md` §12.2 items 1 to 8), the 7g benchmark script, 7h part 1 (event loop and files) and ranges (8a); small items stay open in 7c, 7e (loader validation for opcodes as they land) and 7f | Checked programs run on the VM with the evaluator's exit code, stdout, program stderr and diagnostic codes, now recorded as golden outputs |
| 6 | **Complete:** 7h tasks with one scheduler (N=1) on the structures split for N (`docs/vm/10-io-multicore.md` §10.2.3), with the fairness rule of §10.2.1 (long builtins charge the turn, never `--max-steps`) and the latency test of the 7h tasks item | Concurrent programs on the VM; timers and I/O stay responsive while other tasks compute |
| 7 | **Complete:** the VM is the default backend (7i, first item): `agentica file.agc` runs on the VM; programs that use `TCP`, `TLS`, `HTTP` or `BDD`, and `agentica test`, fall back to the evaluator; the differential tests became golden tests; the release ships `agentica-vm` | One backend for almost every program; CI runs each test once |
| 7.1 | **Next, catch-up:** 7h processes (done), then VM tracing (14a, `docs/future/24-logging.md` §24.4), then TCP and TLS, then HTTP, then BDD on the VM (7h); each PR removes its fallback | Every example, CI smoke test and `agentica test` runs on the VM |
| 7.2 | 7i: delete the evaluator and its runtime modules; the Racket front end (lexer, parser, checker, lowering, bytecode) stays | One backend |
| 7.3 | New features, VM-only: binary data (phase 13, `docs/future/23-binary-data.md` §23), then UDP, then logging and debugging (14b stack traces, then 14c `std/log`, `docs/future/24-logging.md` §24), then the `Crypto` module (`docs/future/20-crypto.md` §20: hashes, HMAC, constant-time compare, random bytes, password hashing and AEAD on OpenSSL 3; needs `Bytes`) | Programs read and write binary numbers with `std/binary` and send UDP; agents see the call stack of a runtime error; programs log with levels, fields and JSON lines, and sign, hash and encrypt |
| 7.4 | New features, VM-only (cont.): Ruby typed idioms (phase 15, `docs/future/25-ruby-typed-idioms.md` §25, Part A, one way to do each thing): defaults, re-exports, `with`, value equality, lambdas, `File.open` with a block, heredocs (15a to 15e, 15i, 15j), then `std/log` defaults in place of the `_with` functions (15l, after 14c); one small PR each | Agents write the Ruby forms they know, still checked, immutable and with one canonical form |
| 8 | Faster lists (8d): a persistent vector behind `List`, before any instruction-dispatch micro-optimization (7g); then the review of what the VM inherited from Racket (7k), next to the 7g hot spots | `push` stops copying the whole list; list-heavy programs stop being O(n²); the VM keeps Racket's rules only where they are good on their own |
| 8.1 | VM layers (7l, `docs/future/21-vm-layers.md` §21); after the tasks PR, next to 7k | The prerequisites of the JIT |
| 8.2 | Ruby typed idioms, prelude part (15f, 15k; `docs/future/25-ruby-typed-idioms.md` §25.6 and §25.11): the compiler prelude with the Enumerable methods, then `format`; after faster lists (8d), since the prelude's cost contract needs them | Enumerable methods and `format`, written in Agentica, O(n) on the new lists |
| 9 | Server measurement on the VM (7j), with the source → result runner (7g) | Requests/s, p50/p99 latency (also while a CPU-bound task runs), peak memory and real start-up, against Python as an outside reference |
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
  The prelude has the only guarded exceptions to "no internal helper
  builtins": `__fail_arg` and `__float_fixed`, which the loader accepts
  only in prelude functions.
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
| [`pending-general-programming-and-mcp.md`](pending-general-programming-and-mcp.md) | Pending work: general programming and MCP (everyday library, typed JSON, modules, real applications, MCP) |
| [`ruby-style-ergonomics.md`](ruby-style-ergonomics.md) | Ruby-style ergonomics (complete) |
| [`later-extensions.md`](later-extensions.md) | Later extensions and open decisions |
| [`done.md`](done.md) | Completed phases 1 to 5h and the completed foundations (5j, BDD features, 5j2, 5k, 5n) |

Planned syntax is in [`docs/future/`](../future/README.md).
