# Agentica: future grammar

Status: proposals only. This document is not normative; implemented language behavior is specified in [`grammar.md`](../grammar.md).

Working rule: when a phase of the [roadmap](../roadmap/README.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

Section 14 records ideas that were decided or rejected, so they are not proposed again. Section 18 records an implementation decision that is deferred. Sections 19 (SIMD in the VM), 21 (VM layers) and 22 (JIT) are implementation proposals with no language change. Section 23 (binary data) adds `Int` and `Float` builtins and the `std/binary` module, with no grammar change. Section 24 (logging and debugging) adds the `std/log` module, stack traces on runtime errors and tracing inside the VM, with no grammar change. Section 25 (Ruby typed idioms) plans more Ruby forms for after 7i, lists others to evaluate later, and records the ones decided against. Section 26 (strict diagnostics) records that Agentica has no warnings and plans four new errors: unused imports, unused variables, unreachable code and ignored `Result` values. Section 27 (iteration and concurrent collections) plans `Task.map` and channels as C builtins and `Task.await` with a timeout as prelude code over channels, keeps lazy streams to evaluate later, and records generators, fibers, Agent-style shared state and public locks as decided against. Section 28 (VM metrics) plans Prometheus metrics for `agentica-vm`, with no language change. Section 29 (TLS contexts) plans `TlsContext`, an immutable handle built once and shared by connections, which replaces the TLS file paths of `TLS` and `HTTP` in one breaking step, and `TLS.upgrade` (STARTTLS). Section 30 (HTTP on the VM) plans simple, synchronous HTTP for the catch-up, with parsing and framing in C and the rest in Agentica as `std/http`, and then streaming bodies on channels. Section 31 (BDD in Agentica) plans BDD on the VM as the `std/bdd` module and a runner written in Agentica, with a child VM per scenario, an explicit step context instead of the implicit current scenario (a breaking change to the BDD API), and three small builtins (`Process.spawn_captured`, `Process.output`, `Task.pending_count`). Section 32 (doc comments) plans `##` documentation lines attached to declarations, `agentica doc` and `help` for `std/` modules; front end only, so it comes before 7i. Section 33 (digit separators) plans `_` between digits in number literals (`1_000`); lexer only, so it also comes before 7i.


## Files

Each numbered section has its own file, named by its number, so `§23` is in `23-binary-data.md`. Sections that have landed or were decided are in [`done.md`](done.md). Section 1 no longer exists.

| § | Title | File | Status |
|---|---|---|---|
| 2 | Landed: enums and pattern matching | [`done.md`](done.md#2-landed-enums-and-pattern-matching) | Landed; spec in `grammar.md` |
| 3 | Extensions without a normative grammar | [`03-extensions.md`](03-extensions.md) | Proposals |
| 4 | Standard library and function values | [`04-stdlib-and-function-values.md`](04-stdlib-and-function-values.md) | Mostly landed; the rest is planned |
| 5 | Remaining `List` operations | [`05-list-operations.md`](05-list-operations.md) | Mostly landed; other gaps listed |
| 6 | Native runtime | [`06-native-runtime.md`](06-native-runtime.md) | Replaced by the bytecode VM ([`docs/vm/`](../vm/README.md)) |
| 7 | Possible metatables: Ruby-style modules | [`07-metatables.md`](07-metatables.md) | Not planned: see §25 |
| 8 | Concurrency and parallelism | [`08-concurrency.md`](08-concurrency.md) | Tasks landed; channels planned in §27; CPU parallelism proposed |
| 9 | Files and paths | [`done.md`](done.md#9-files-and-paths-implemented) | Implemented |
| 10 | Void and processes | [`done.md`](done.md#10-void-and-processes-implemented) | Implemented |
| 11 | Ruby-style ergonomics | [`11-ruby-ergonomics.md`](11-ruby-ergonomics.md) | Implemented; its rule for new forms still applies; a few items open |
| 12 | Data structures | [`12-data-structures.md`](12-data-structures.md) | Ranges landed; sets, queues and faster lists planned (roadmap phase 8) |
| 13 | Shared tables (ATS) | [`13-ats.md`](13-ats.md) | On demand (roadmap phase 9) |
| 14 | Decided: no shadowing | [`done.md`](done.md#14-decided-no-shadowing) | Decided |
| 15 | Adapters and JSON inspection | [`15-adapters-and-json-inspection.md`](15-adapters-and-json-inspection.md) | Planned (roadmap phase 10) |
| 16 | Binary serialization (CBOR) | [`16-cbor.md`](16-cbor.md) | On demand (roadmap phase 11) |
| 17 | Optional and nullable JSON fields | [`17-optional-json-fields.md`](17-optional-json-fields.md) | Planned (roadmap 10e) |
| 18 | Front-end implementation language | [`18-front-end-language.md`](18-front-end-language.md) | Deferred decision |
| 19 | SIMD in the VM | [`19-simd.md`](19-simd.md) | On demand |
| 20 | Crypto module | [`20-crypto.md`](20-crypto.md) | Planned after 7i (roadmap order step 7.5) |
| 21 | VM layers | [`21-vm-layers.md`](21-vm-layers.md) | Planned (roadmap 7l) |
| 22 | JIT | [`22-jit.md`](22-jit.md) | Required (roadmap 7m) |
| 23 | Binary data | [`23-binary-data.md`](23-binary-data.md) | Planned (roadmap phase 13) |
| 24 | Logging and debugging | [`24-logging.md`](24-logging.md) | Planned (roadmap phase 14) |
| 25 | Ruby typed idioms | [`25-ruby-typed-idioms.md`](25-ruby-typed-idioms.md) | Part A planned (roadmap phase 15); Part B to evaluate later; Part C decided against |
| 26 | Strict diagnostics | [`26-strict-diagnostics.md`](26-strict-diagnostics.md) | Planned (roadmap phase 16) |
| 27 | Iteration and concurrent collections | [`27-iteration-and-concurrency.md`](27-iteration-and-concurrency.md) | `Task.map`, channels and `Task.await` with a timeout planned (roadmap phase 17); lazy streams to evaluate later; generators and shared state decided against |
| 28 | VM metrics | [`28-vm-metrics.md`](28-vm-metrics.md) | Planned (roadmap phase 18) |
| 29 | TLS contexts | [`29-tls-context.md`](29-tls-context.md) | Planned (roadmap phase 19, order step 7.4) |
| 30 | HTTP on the VM: simple, synchronous, hybrid | [`30-hybrid-http.md`](30-hybrid-http.md) | Planned (roadmap phase 20: 20a to 20d in the catch-up, order step 7.1; streaming 20e to 20g at order step 7.4) |
| 31 | BDD in Agentica | [`31-bdd-in-agentica.md`](31-bdd-in-agentica.md) | Planned (roadmap phase 21, catch-up item 7h, before 7i) |
| 32 | Doc comments | [`32-doc-comments.md`](32-doc-comments.md) | Planned (roadmap phase 22, after HTTP 20a and before 20b) |
| 33 | Digit separators | [`33-digit-separators.md`](33-digit-separators.md) | Planned (roadmap phase 23, after phase 22 and before HTTP 20b) |

New features are VM-only: they come after the evaluator is deleted (roadmap 7i; exceptions: HTTP 20a to 20d, doc comments and digit separators, see the roadmap rules) and get no Racket twin ([roadmap rules](../roadmap/README.md#rules-for-the-catch-up-and-new-features)).

The rule "New library features: `std/` first" (a new pure library feature starts as a `std/` module written in Agentica, not as a builtin) lives in the roadmap: [`../roadmap/README.md`](../roadmap/README.md#new-library-features-std-first).
