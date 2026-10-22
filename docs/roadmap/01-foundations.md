# Roadmap: foundations (phases 1 to 5n, complete)

Phases 1 to 5h and the completed foundations for general programming and MCP.
They were built on the Racket evaluator, which the VM replaced (phase 7, 7i);
the language they define is specified in [`docs/grammar.md`](../grammar.md) and
its files in `docs/grammar/`, and the tests of each stage are in
`tests/test_*.py`. The current order is in [`README.md`](README.md).

**Still open from this period** (both tracked here until they are done or
dropped):

- [ ] Phase 5d3, the rest of the agent API: the measurement of `--ai` and labels
  against plain text on the `binary` arm (`docs/eval.md`). The commands `symbol`
  and `refs` are built as part of the semantic CLI (row 7.2b,
  [§39](../future/39-semantic-cli.md)); `show` was dropped (owner, 2026-10-21):
  `symbol` and `type-at` give the signature, the doc and the definition.
- [ ] Phase 6a, the Sonnet 5.5 round (postponed; only `pi` for now). Rounds 1 to
  8 are done and recorded in `docs/eval.md`; see
  [`06-validation.md`](06-validation.md).

## Done

Each phase is specified in the grammar (`docs/grammar/`) and tested in
`tests/test_*.py`; git history keeps the per-phase records.

- **1 to 5:** lexer (`LEX-`), parser (`PARSE-`, every node carries a span),
  checker (`CHECK-`), the core evaluator (`RUNTIME-`, replaced by the VM in
  phase 7) and the CLI (the first diagnostic to stderr and exit 1; a missing
  file or bad usage exits 2). Every grammar example is a test
  (`tests/test_examples.py`).
- **5b to 5h:** maps, strings, `IO` and `System`, consistency fixes
  (`--max-steps`), the agent API of `agentica check` (plain, `--ai`, `--json`;
  grounded suggestions only), `Result` and `try` with the builtin catalog, JSON,
  TCP and TLS, and HTTP (now `std/http`, phase 20).
- **6a:** the first agent evaluation (`docs/eval.md`, `tests/eval/`).
- **5j, 5j2, 5k, 5n:** function values (`Fn`, `&name`, `.call`), BDD features
  (now `std/bdd`, [phase 21](21-bdd-in-agentica.md)), lightweight tasks, `try`,
  and the collection primitives.

Rules from these phases that stay: each stage takes the previous stage's output
and returns data or exactly one diagnostic, stops at the first error, never
prints and never lets a front-end exception escape (also in `AGENTS.md`).
Diagnostic codes are stable and prefixed by stage. Internal checker cases that
should never happen have their own code, `CHECK-INTERNAL`.

**Decisions of this period** (all closed):

- `?` and `!` are part of function names for every function, as in Ruby and
  Elixir (`String.contains?`, `String.to_int!`).
- Names and shapes copy Ruby and Elixir so an agent can guess them; every
  function that can fail has two forms: `x(...)` returns `Result[T]` and
  `x!(...)` halts with a `RUNTIME-` diagnostic.
- `Map.has` and `Map.len` became `Map.has_key?` and `Map.size`, with `List.len`
  becoming `List.size` (5c). `m[k] = v` stays
  `PARSE-INVALID-ASSIGNMENT-TARGET` with a hint to use `Map.put`.
- `List` is the collection module (no `Enum` beside the `enum` keyword).
- Network and filesystem access use host permissions, with no separate
  capability flag.

**Independent integration fixtures** (the rule that came with 5g and 5h, kept in
`AGENTS.md`): TCP/HTTP interoperability tests use a protocol implementation
independent of the Agentica code under test (Node's `http`, `https`, `net`,
Python's `http.server` and `socket`, or curl), standard libraries only,
localhost, port 0, no external services, with cleanup of processes and ports on
every exit. Fixtures live in `tests/fixtures/`. Local runs may skip with a
visible message when the tool is missing; CI installs Node and must fail rather
than skip. A test against the official MCP SDK needs `npx` and the network, so
it stays manual and out of CI.
