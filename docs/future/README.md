# Agentica: future grammar

Status: proposals only. This document is not normative; implemented language
behavior is specified in [`grammar.md`](../grammar.md).

Working rule: when a phase of the [roadmap](../roadmap/README.md) finishes, its
syntax moves from this document to the language reference in `docs/grammar/`
(index: [`grammar.md`](../grammar.md)) and is deleted from here.

Section 14 records ideas that were decided or rejected, so they are not proposed
again. Section 18 records the history of the front-end language question, which
section 35 decides. Sections 19 (SIMD in the VM), 21 (VM layers) and 22 (JIT)
are implementation proposals with no language change. Section 23 (binary data)
adds `Int` and `Float` builtins and the `std/binary` module, with no grammar
change. Section 24 (logging and debugging) adds the `std/log` module, stack
traces on runtime errors and tracing inside the VM, with no grammar change.
Section 25 (Ruby typed idioms) plans more Ruby forms for after 7i, lists others
to evaluate later, and records the ones decided against. Section 26 (strict
diagnostics) records that Agentica has no warnings and plans four new errors:
unused imports, unused variables, unreachable code and ignored `Result` values.
Section 27 (iteration and concurrent collections) plans `Task.map`, channels and
`Task.await` with a timeout (returning the builtin enum `Await[T]`) as C
builtins, and `File.each_line` (C) and a lazy `Stream[T]` (prelude code) in two
steps, and records generators, fibers, Agent-style shared state and public locks
as decided against. Section 28 (VM metrics) plans Prometheus metrics for
`agentica-vm`, with no language change. Section 29 (TLS contexts) plans
`TlsContext`, an immutable handle built once and shared by connections, which
replaces the TLS file paths of `TLS` and `HTTP` in one breaking step, and
`TLS.upgrade` (STARTTLS). Section 30 (HTTP on the VM) keeps the pending
streaming bodies on channels and the later binary bodies; the simple,
synchronous HTTP of 20a to 20c is built and specified in
[`docs/vm/10-io-http.md`](../vm/10-io-http.md) and
[`docs/grammar/06d-io-and-network.md`](../grammar/06d-io-and-network.md). BDD in
Agentica (formerly section 31) is built and specified in
[`docs/bdd.md`](../bdd.md). Section 32 (doc comments) plans `##` documentation
lines attached to declarations, `agentica doc` and `help` for `std/` modules;
front end only, after 7i, HTTP 20b, sections 37 and 36, and HTTP 20c. Section 33
(digit separators) plans `_` between digits in number literals (`1_000`); lexer
only, right after section 32. Section 34 (shared small values) is a VM
implementation proposal with no language change: one shared object per run for
`""`, the one-character ASCII strings, `[]`, `{}` and later the empty `Set`,
kept only if a benchmark shows it helps. Section 35 (self-hosted front end)
records the owner's decision of 2026-10-13: the front end is rewritten in
Agentica and embedded in the VM, so the release is one binary that starts in
tens of milliseconds; a long-term item after the current roadmap order. Section
36 (unit tests) plans the builtin `Test` module (`Test.test`, `Test.run` and
four assertions that return `Result[Void]`) and runs `*_test.agc` files with
`agentica test` next to the features, a child VM per file and a task per test.
Section 37 (task crash isolation) proposes, in the style of Erlang, that a
runtime error in a task other than `main` ends only that task: its awaiters get
an error `Result`, its descendants are cancelled and the handles it owns are
closed. Section 38 (value representation) records why `agc_value` is 16 bytes,
the smaller layouts that were weighed, and the direction if it ever changes:
unboxed storage from the static types; no change is planned. Section 39
(semantic CLI for agents) plans `agentica outline`, `symbol`, `refs` and
`type-at`: questions about checked code answered as text or versioned JSON, with
`QUERY-` codes; front end and CLI only, no LSP, no language change. Section 40
(native code and FFI) is an idea outside the roadmap order: the JIT first
(section 22), then an `extern def` FFI into native libraries behind an explicit
flag when a library needs it, and AOT last; the JIT changes no language, and the
FFI syntax is only a sketch.


## Files

Each numbered section has its own file, named by its number, so `§23` is in
`23-binary-data.md`. Sections that have landed or were decided are in
[`done.md`](done.md). Sections 1 and 31 have no file here: section 31 (BDD) is
built and specified in [`docs/bdd.md`](../bdd.md).

| § | Title | File | Status |
|---|---|---|---|
| 2 | Landed: enums and pattern matching | [`done.md`](done.md#2-landed-enums-and-pattern-matching) | Landed; spec in `docs/grammar/` |
| 3 | Extensions without a normative grammar | [`03-extensions.md`](03-extensions.md) | Proposals |
| 4 | Standard library and function values | [`04-stdlib-and-function-values.md`](04-stdlib-and-function-values.md) | Mostly landed; the rest is planned |
| 5 | Remaining `List` operations | [`05-list-operations.md`](05-list-operations.md) | Mostly landed; other gaps listed |
| 6 | Native runtime | [`06-native-runtime.md`](06-native-runtime.md) | Replaced by the bytecode VM ([`docs/vm/`](../vm/README.md)) |
| 7 | Possible metatables: Ruby-style modules | [`07-metatables.md`](07-metatables.md) | Not planned: see §25 |
| 8 | Concurrency and parallelism | [`08-concurrency.md`](08-concurrency.md) | Tasks landed; channels built (§27.2); open questions only; CPU parallelism proposed |
| 9 | Files and paths | [`done.md`](done.md#9-files-and-paths-implemented) | Implemented |
| 10 | Void and processes | [`done.md`](done.md#10-void-and-processes-implemented) | Implemented |
| 11 | Ruby-style ergonomics | [`11-ruby-ergonomics.md`](11-ruby-ergonomics.md) | Implemented; its rule for new forms still applies; a few items open |
| 12 | Data structures | [`12-data-structures.md`](12-data-structures.md) | Ranges landed; sets, queues and faster lists planned (roadmap phase 8) |
| 13 | Shared tables (ATS) | [`13-ats.md`](13-ats.md) | On demand (roadmap phase 9) |
| 14 | Decided: no shadowing | [`done.md`](done.md#14-decided-no-shadowing) | Decided |
| 15 | Adapters and JSON inspection | [`15-adapters-and-json-inspection.md`](15-adapters-and-json-inspection.md) | Planned (roadmap phase 10) |
| 16 | Binary serialization (CBOR) | [`16-cbor.md`](16-cbor.md) | On demand (roadmap phase 11) |
| 17 | Optional and nullable JSON fields | [`17-optional-json-fields.md`](17-optional-json-fields.md) | Planned (roadmap 10e) |
| 18 | Front-end implementation language | [`18-front-end-language.md`](18-front-end-language.md) | Decided in §35: self-hosting |
| 19 | SIMD in the VM | [`19-simd.md`](19-simd.md) | On demand |
| 20 | Crypto module | [`20-crypto.md`](20-crypto.md) | Planned after 7i (roadmap order step 7.5) |
| 21 | VM layers | [`21-vm-layers.md`](21-vm-layers.md) | Planned (roadmap 7l) |
| 22 | JIT | [`22-jit.md`](22-jit.md) | Required (roadmap 7m) |
| 23 | Binary data | [`23-binary-data.md`](23-binary-data.md) | Done (roadmap phase 13) |
| 24 | Logging and debugging | [`24-logging.md`](24-logging.md) | Planned (roadmap phase 14) |
| 25 | Ruby typed idioms | [`25-ruby-typed-idioms.md`](25-ruby-typed-idioms.md) | Part A planned (roadmap phase 15); Part B to evaluate later; Part C decided against |
| 26 | Strict diagnostics | [`26-strict-diagnostics.md`](26-strict-diagnostics.md) | Planned (roadmap phase 16) |
| 27 | Iteration and concurrent collections | [`27-iteration-and-concurrency.md`](27-iteration-and-concurrency.md) | Channels (17b) and `Task.await` with a timeout (17c) built; `Task.map` planned (roadmap phase 17); `File.each_line` built (17d), `Stream[T]` planned (17e); generators and shared state decided against |
| 28 | VM metrics | [`28-vm-metrics.md`](28-vm-metrics.md) | Planned (roadmap phase 18) |
| 29 | TLS contexts | [`29-tls-context.md`](29-tls-context.md) | Planned (roadmap phase 19, order step 7.4) |
| 30 | HTTP on the VM: simple, synchronous, hybrid | [`30-hybrid-http.md`](30-hybrid-http.md) | Streaming (roadmap 20e to 20g, order step 7.4) and binary bodies planned; the rest of phase 20 is built: [`docs/vm/10-io-http.md`](../vm/10-io-http.md) |
| 32 | Doc comments | [`32-doc-comments.md`](32-doc-comments.md) | 22a built, 22b planned (roadmap phase 22, order step 7.2a) |
| 33 | Digit separators | [`33-digit-separators.md`](33-digit-separators.md) | Done (roadmap phase 23, 23a) |
| 34 | Shared small values in the VM | [`34-shared-small-values.md`](34-shared-small-values.md) | Candidate (roadmap 7g); needs a measurement |
| 35 | Self-hosted front end and a single binary | [`35-self-hosting.md`](35-self-hosting.md) | Planned, in the roadmap order from row 7.2.7 on |
| 36 | Unit tests (`Test`) | [`36-unit-tests.md`](36-unit-tests.md) | `Test` module done (25a); `agentica test` for test files planned (25b) |
| 37 | Task crash isolation | [`37-task-crash-isolation.md`](37-task-crash-isolation.md) | Planned (roadmap phase 24, after 7i and 20b); semantics for the owner to review |
| 38 | Value representation | [`38-value-representation.md`](38-value-representation.md) | Note, no change planned; revisit with 8d and the benchmarks (roadmap order rows 9 and 14) |
| 39 | Semantic CLI for agents | [`39-semantic-cli.md`](39-semantic-cli.md) | Planned (roadmap phase 26, order step 7.2b) |
| 40 | Native code and FFI | [`40-native-code.md`](40-native-code.md) | Idea, not in the roadmap order: the JIT (roadmap 9.1) first; FFI and AOT wait for a need or a measurement |
| 41 | Dates and times | [`41-dates-and-times.md`](41-dates-and-times.md) | Designed by the owner's scope of 2026-10-14; not scheduled |
| 42 | Sized numeric types | [`42-sized-numeric-types.md`](42-sized-numeric-types.md) | Designed by the owner's scope of 2026-10-14; implement after the bootstrap (§35) |

New features are VM-only (roadmap 7i deleted the evaluator) and get no Racket
twin ([roadmap
rules](../roadmap/README.md#rules-for-the-catch-up-and-new-features)).

The rule "New library features: `std/` first" (a new pure library feature starts
as a `std/` module written in Agentica, not as a builtin) lives in the roadmap:
[`../roadmap/README.md`](../roadmap/README.md#new-library-features-std-first).
