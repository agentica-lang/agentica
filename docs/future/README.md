# Agentica: future grammar

This index tracks future proposals; the current language contract is in
[`grammar.md`](../grammar.md). Requirements and rationale stay in each linked
spec. When a phase of the [roadmap](../roadmap/README.md) lands, move its syntax
to `docs/grammar/` and delete it here, preserving section numbers.

Sections 19, 21 and 22 are VM implementation proposals, not language changes.
Section 20 adds crypto without changing the grammar; binary data (§23) and
logging (§24) are built and live in the grammar. Sections 25–34 cover Ruby
idioms, diagnostics, concurrency, VM metrics, TLS, HTTP, BDD, doc comments and
VM values. Sections 36 and 38–40 cover unit tests, value
representation, semantic CLI and native code; task crash isolation (§37) is
built. Sections 41–43 cover date/time types, sized numerics and an unscheduled
language server. The Files index carries current status; linked sections keep
requirements, rationale and alternatives.


## Files

Each section links to its proposal or current home; §6 points to the VM design,
§7 to §25.13, and §18 records the front-end language decision and the
self-hosted bootstrap. Sections 1, 2, 5, 8–12, 14, 21, 23, 24, 33, 35 and 37
have no
file of their own: they are built or decided, and their content lives in the
grammar, `docs/vm/`, the roadmap or §18. §31 (BDD) is built and specified in
[`docs/bdd.md`](../bdd.md).

- §: 3
  - Title: Extensions without a normative grammar
  - File: [`03-extensions.md`](03-extensions.md)
  - Status: Proposals

- §: 4
  - Title: Standard library and function values
  - File:
    [`04-stdlib-and-function-values.md`](04-stdlib-and-function-values.md)
  - Status: Mostly landed; the rest is planned

- §: 6
  - Title: Native runtime
  - File: [`VM design`](../vm/README.md)
  - Status: Replaced by the C bytecode VM

- §: 7
  - Title: Possible metatables: Ruby-style modules
  - File: [Decided against](25-ruby-typed-idioms.md#2513-decided-against-part-c)
  - Status: Not planned; rationale in §25.13

- §: 13
  - Title: Shared tables (ATS)
  - File: [`13-ats.md`](13-ats.md)
  - Status: On demand (roadmap phase 9)

- §: 15
  - Title: Adapters and JSON inspection
  - File:
    [`15-adapters-and-json-inspection.md`](15-adapters-and-json-inspection.md)
  - Status: Planned (roadmap phase 10)

- §: 16
  - Title: Binary serialization (CBOR)
  - File: [`16-cbor.md`](16-cbor.md)
  - Status: On demand (roadmap phase 11)

- §: 17
  - Title: Optional and nullable JSON fields
  - File: [`17-optional-json-fields.md`](17-optional-json-fields.md)
  - Status: Planned (roadmap 10e)

- §: 18
  - Title: Front-end implementation language (self-hosting; done)
  - File: [`18-front-end-language.md`](18-front-end-language.md)
  - Status: Decision and bootstrap done; the remaining work is in the roadmap

- §: 19
  - Title: SIMD in the VM
  - File: [`19-simd.md`](19-simd.md)
  - Status: On demand

- §: 20
  - Title: Crypto module
  - File: [`20-crypto.md`](20-crypto.md)
  - Status: Planned after 7i (roadmap order step 7.5)

- §: 22
  - Title: JIT
  - File: [`22-jit.md`](22-jit.md)
  - Status: Required (roadmap 7m)

- §: 25
  - Title: Ruby typed idioms
  - File: [`25-ruby-typed-idioms.md`](25-ruby-typed-idioms.md)
  - Status: 25.1, 25.3, 25.6, 25.10, 25.12.1 and 25.14 built (the grammar and
    the programming skill are the contract); 25.2, 25.4, 25.5, 25.9 and 25.11
    planned (roadmap phase 15); Part B to evaluate later; Part C decided against

- §: 26
  - Title: Strict diagnostics
  - File: [`26-strict-diagnostics.md`](26-strict-diagnostics.md)
  - Status: Planned (roadmap phase 16)

- §: 27
  - Title: Iteration and concurrent collections
  - File:
    [`27-iteration-and-concurrency.md`](27-iteration-and-concurrency.md)
  - Status: Channels (17b) and `Task.await` with a timeout (17c) built;
    `Task.map` planned (roadmap phase 17); `File.each_line` built (17d),
    `Stream[T]` planned (17e); generators and shared state decided against

- §: 28
  - Title: VM metrics
  - File: [`28-vm-metrics.md`](28-vm-metrics.md)
  - Status: Planned (roadmap phase 18)

- §: 29
  - Title: TLS contexts
  - File: [`29-tls-context.md`](29-tls-context.md)
  - Status: Planned (roadmap phase 19, order step 7.4)

- §: 30
  - Title: HTTP on the VM: simple, synchronous, hybrid
  - File: [`30-hybrid-http.md`](30-hybrid-http.md)
  - Status: Streaming (roadmap 20e to 20g, order step 7.4) and binary bodies
    planned; the rest of phase 20 is built:
    [`docs/vm/10-io-http.md`](../vm/10-io-http.md)

- §: 32
  - Title: Doc comments
  - File: [`32-doc-comments.md`](32-doc-comments.md)
  - Status: 22a built (roadmap phase 22, order step 7.2a); 22b (`agentica
    doc`) waits until after the bootstrap (row 22b)

- §: 34
  - Title: Shared small values in the VM
  - File: [`34-shared-small-values.md`](34-shared-small-values.md)
  - Status: Built (roadmap 7g, 2026-10-16)

- §: 36
  - Title: Unit tests (`Test`)
  - File: [`36-unit-tests.md`](36-unit-tests.md)
  - Status: `Test` module done (25a); `agentica test` for test files planned
    (25b)

- §: 38
  - Title: Value representation
  - File: [`38-value-representation.md`](38-value-representation.md)
  - Status: Note, no change planned; revisit with 8d and the benchmarks
    (roadmap order rows 9 and 14)

- §: 39
  - Title: Semantic CLI for agents
  - File: [`39-semantic-cli.md`](39-semantic-cli.md)
  - Status: Planned (roadmap phase 26, order step 7.2b)

- §: 40
  - Title: Native code and FFI
  - File: [`40-native-code.md`](40-native-code.md)
  - Status: Decided by the owner on 2026-10-15: the FFI before the JIT
    (roadmap 9.1), after the bootstrap; AOT last, only if measurements ask for
    it

- §: 41
  - Title: Dates and times
  - File: [`41-dates-and-times.md`](41-dates-and-times.md)
  - Status: Designed by the owner's scope of 2026-10-14; the types wait
    until after the bootstrap (§18, 41.13); `Time.monotonic_ns` may land earlier

- §: 42
  - Title: Sized numeric types
  - File: [`42-sized-numeric-types.md`](42-sized-numeric-types.md)
  - Status: Designed by the owner's scope of 2026-10-14; implement after the
    bootstrap (§18)

- §: 43
  - Title: Language server (LSP)
  - File: [`43-language-server.md`](43-language-server.md)
  - Status: Idea, not scheduled (the owner asked on 2026-10-15 to note it);
    reuses §39 and §32

- §: 44
  - Title: Module constants and imports
  - File: [`44-module-constants.md`](44-module-constants.md)
  - Status: Planned (roadmap row 7.2.8): new import forms (`import Mod from
    "path"`, `import {A} from "path"`) first, then module constants; before the
    bootstrap, by the owner's decision of 2026-10-15; relaxes the freeze of row
    7.2.7

- §: 45
  - Title: Packages
  - File: [`45-packages.md`](45-packages.md)
  - Status: Design, not scheduled; decided by the owner on 2026-10-15:
    `std/toml` first (45-0, may land before the bootstrap), TOML manifest and
    lock, `Toml.Value` decode, `owner/repo` imports; the manager waits for after
    the bootstrap (port step 8); asked by the owner on 2026-10-15

- §: 46
  - Title: Signals
  - File: [`46-signals.md`](46-signals.md)
  - Status: Scheduled on 2026-10-15, after the bootstrap (phase 27,
    [`docs/roadmap/27-signals.md`](../roadmap/27-signals.md)): catch TERM and
    INT for a safe shutdown, forward signals to children, signal a process
    group; 46a and 46b (VM code and builtin table rows) may come earlier

- §: 47
  - Title: Code formatter (`agentica fmt`)
  - File: [`47-formatter.md`](47-formatter.md)
  - Status: Deferred until after the bootstrap (port step 8, roadmap row 7.9,
    phase 28), decided by the owner on 2026-10-15; 47d waits for the LSP (§43)

- §: 48
  - Title: Regular expressions
  - File: [`48-regex.md`](48-regex.md)
  - Status: Decided by the owner on 2026-10-15; deferred until after the
    bootstrap (roadmap row 7.10, phase 29): `std/regex` in Agentica first, then
    the regex literal `/pattern/flags`

- §: 49
  - Title: Type aliases
  - File: [`49-type-aliases.md`](49-type-aliases.md)
  - Status: Planned by the owner on 2026-10-16 (roadmap row 7.12, phase 30):
    simple transparent aliases (49a), then generic ones (49b); compiler/ only

- §: 50
  - Title: Test functions without `main`
  - File: [`50-test-functions.md`](50-test-functions.md)
  - Status: Planned (roadmap phase 31, order row 7.11, post-bootstrap step
    6): a `*_test.agc` file may have no `main`; its top-level `test_*` functions
    are its tests

New features are VM-only (roadmap 7i deleted the evaluator) and get no second
implementation ([roadmap
rules](../roadmap/README.md#rules-for-the-catch-up-and-new-features)).

The rule "New library features: `std/` first" (a new pure library feature starts
as a `std/` module written in Agentica, not as a builtin) lives in the roadmap:
[`../roadmap/README.md`](../roadmap/README.md#new-library-features-std-first).
