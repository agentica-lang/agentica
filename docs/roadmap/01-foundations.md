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

Phases 1 to 5n and 6a (lexer, parser, checker, CLI, the agent API of `agentica
check`, `Result` and `try`, JSON, TCP, TLS, HTTP, function values, tasks, the
collection primitives and the first evaluation, `docs/eval.md`) are specified
in the grammar and tested in `tests/test_*.py`; git history keeps the per-phase
records. Internal checker cases that should never happen have their own code,
`CHECK-INTERNAL`. The stage and diagnostic-code rules are in `AGENTS.md`.

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

A test against the official MCP SDK needs `npx` and the network, so it stays
manual and out of CI. The rules for independent peers are in `AGENTS.md`.
