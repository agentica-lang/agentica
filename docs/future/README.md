# Agentica: future grammar

This index tracks future proposals; the current language contract is in
[`grammar.md`](../grammar.md). Requirements and rationale stay in each linked
spec. When a phase of the [roadmap](../roadmap/README.md) lands, move its syntax
to `docs/grammar/` and delete it here, preserving section numbers.

Sections 19 and 22 are VM implementation proposals, not language changes;
section 20 adds crypto without changing the grammar. The Files index carries
current status; linked sections keep requirements, rationale and alternatives.

## Files

Sections 1, 2, 5, 8–14, 21, 23, 24, 33, 35–37 and 49 have no file of their
own: they are built or decided, and their content lives in the grammar,
`docs/vm/`, the roadmap or §18. §31 (BDD) is built and specified in
[`docs/bdd.md`](../bdd.md); §34 stays here as the VM record of built
small-value sharing. §40 (native code and FFI) was replaced by issue
[#534](https://github.com/sonic182/agentica/issues/534), which holds its design.

- §: 3
  - Title: Extensions without a normative grammar
  - File: [`03-extensions.md`](03-extensions.md)
  - Status: Proposals

- §: 4
  - Title: Standard library and function values
  - File:
    [`04-stdlib-and-function-values.md`](04-stdlib-and-function-values.md)
  - Status: Built; two rules wait for a home in the grammar

- §: 6
  - Title: Native runtime
  - File: [`VM design`](../vm/README.md)
  - Status: Replaced by the C bytecode VM

- §: 7
  - Title: Possible metatables: Ruby-style modules
  - File: [Decided against](25-ruby-typed-idioms.md#2513-decided-against-part-c)
  - Status: Not planned; rationale in §25.13

- §: 15
  - Title: Adapters and JSON inspection
  - File:
    [`15-adapters-and-json-inspection.md`](15-adapters-and-json-inspection.md)
  - Status: Planned (row 7.6)

- §: 16
  - Title: Binary serialization (CBOR)
  - File: [`16-cbor.md`](16-cbor.md)
  - Status: On demand (row 18)

- §: 17
  - Title: Optional and nullable JSON fields
  - File: [`17-optional-json-fields.md`](17-optional-json-fields.md)
  - Status: Planned (item 10e, row 7.6)

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
  - Status: Planned (row 7.5)

- §: 22
  - Title: JIT
  - File: [`22-jit.md`](22-jit.md)
  - Status: Required (row 9.1)

- §: 25
  - Title: Ruby typed idioms
  - File: [`25-ruby-typed-idioms.md`](25-ruby-typed-idioms.md)
  - Status: 25.1, 25.2, 25.3, 25.6, 25.10, 25.12.1 and 25.14 built (the grammar
    and the programming skill are the contract); 25.4, 25.5, 25.9 and 25.11
    planned (row 7.6); Part B to evaluate later; Part C decided against

- §: 26
  - Title: Strict diagnostics
  - File: [`26-strict-diagnostics.md`](26-strict-diagnostics.md)
  - Status: Planned (row 7.6)

- §: 27
  - Title: Iteration and concurrent collections
  - File:
    [`27-iteration-and-concurrency.md`](27-iteration-and-concurrency.md)
  - Status: `Task.map` (17a), channels (17b), `Task.await` with a timeout
    (17c), `File.each_line` (17d) and `Lazy[T]` over lists, ranges,
    `Lazy.produce`, `File.foreach` and `ch.lazy` (17e) built; generators and
    shared state decided against

- §: 28
  - Title: VM metrics
  - File: [`28-vm-metrics.md`](28-vm-metrics.md)
  - Status: Planned (row 7.7)

- §: 29
  - Title: TLS contexts
  - File: [`29-tls-context.md`](29-tls-context.md)
  - Status: Planned (row 7.4)

- §: 30
  - Title: HTTP on the VM: simple, synchronous, hybrid
  - File: [`30-hybrid-http.md`](30-hybrid-http.md)
  - Status: Streaming (20e to 20g, order step 7.4) and binary bodies
    planned; the rest of phase 20 is built:
    [`docs/vm/10-io-http.md`](../vm/10-io-http.md)

- §: 32
  - Title: Doc comments
  - File: [`32-doc-comments.md`](32-doc-comments.md)
  - Status: 22a built (row 7.2a); `agentica doc` built (row 22b, part 1);
    `agentica help` for `std/` planned (row 22b, part 2)

- §: 34
  - Title: Shared small values in the VM
  - File: [`34-shared-small-values.md`](34-shared-small-values.md)
  - Status: Built (row 7g, 2026-10-16); kept as the VM design record

- §: 38
  - Title: Value representation
  - File: [`38-value-representation.md`](38-value-representation.md)
  - Status: Note, no change planned; revisit with 8d and the benchmarks
    (roadmap order rows 9 and 14)

- §: 39
  - Title: Semantic CLI for agents
  - File: [`39-semantic-cli.md`](39-semantic-cli.md)
  - Status: Built (row 7.2b): `outline`, `symbol`, `refs`, `type-at`,
    `--partial` and `std/analysis`; pending: the 6c measurement (§39.12)

- §: 41
  - Title: Dates and times
  - File: [`41-dates-and-times.md`](41-dates-and-times.md)
  - Status: Designed by the owner's scope of 2026-10-14, not scheduled
    (41.13); `Time.monotonic_ns` has landed

- §: 42
  - Title: Sized numeric types
  - File: [`42-sized-numeric-types.md`](42-sized-numeric-types.md)
  - Status: Designed by the owner's scope of 2026-10-14, not scheduled

- §: 43
  - Title: Language server (LSP)
  - File: [`43-language-server.md`](43-language-server.md)
  - Status: Idea, not scheduled (the owner asked on 2026-10-15 to note it);
    reuses §39 and §32

- §: 45
  - Title: Packages
  - File: [`45-packages.md`](45-packages.md)
  - Status: Built (45-0, 45a to 45d); only FFI-b is left, for 0.10 (issue
    [#534](https://github.com/sonic182/agentica/issues/534))

- §: 46
  - Title: Signals
  - File: [`46-signals.md`](46-signals.md)
  - Status: Weighed later (row 7.8): catch TERM and INT for a safe shutdown,
    forward signals to children, signal a process group; 46a and 46b may run
    earlier when no other VM PR is waiting

- §: 47
  - Title: Code formatter (`agentica fmt`)
  - File: [`47-formatter.md`](47-formatter.md)
  - Status: Second batch of the order after 0.8.0 (row 7.9); 47d waits for the
    LSP (§43)

- §: 48
  - Title: Regular expressions
  - File: [`48-regex.md`](48-regex.md)
  - Status: Weighed later (row 7.10): `std/regex` in Agentica first, then the
    regex literal `/pattern/flags`

- §: 50
  - Title: Test functions without `main`
  - File: [`50-test-functions.md`](50-test-functions.md)
  - Status: Planned (row 7.11, item 14 after 0.8.0): a `*_test.agc` file may
    have no `main`; its top-level `test_*` functions are its tests

New features are VM-only (roadmap 7i deleted the evaluator) and get no second
implementation ([roadmap
rules](../roadmap/README.md#rules-for-the-catch-up-and-new-features)).

The rule "New library features: `std/` first" (a new pure library feature starts
as a `std/` module written in Agentica, not as a builtin) lives in the roadmap:
[`../roadmap/README.md`](../roadmap/README.md#new-library-features-std-first).
