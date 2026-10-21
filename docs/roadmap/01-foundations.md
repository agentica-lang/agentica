# Roadmap: foundations (phases 1 to 5n, complete)

Phases 1 to 5h and the completed foundations for general programming and MCP.
They were built on the Racket evaluator, which the VM replaced (phase 7, 7i);
the language they define is specified in [`docs/grammar.md`](../grammar.md) and
its files in `docs/grammar/`, and the tests of each stage are in
`tests/test_*.py`. The current order is in [`README.md`](README.md).

**Still open from this period** (both tracked here until they are done or
dropped):

- [ ] Phase 5d3, the rest of the agent API: `symbols`, `show` and `refs` with
  one test per command over `examples/`, and the measurement of `--ai` and
  labels against plain text on the `binary` arm (`docs/eval.md`). The semantic
  commands for agents are now planned as [§39](../future/39-semantic-cli.md#39-semantic-cli-for-agents)
  (`outline`, `symbol`, `refs`, `type-at`).
- [ ] Phase 6a, the Sonnet 5.5 round (postponed; only `pi` for now). Rounds 1 to
  8 are done and recorded in `docs/eval.md`; see
  [`06-validation.md`](06-validation.md).

## Phases 1 to 5: the front end and the CLI

- **1.** Source handling and lexer (`LEX-`): grammar §4.
- **2.** AST and parser (`PARSE-`): grammar §5. Every node carries a span; no
  checker or placeholder nodes for later phases.
- **3.** Name resolution and type checking (`CHECK-`): grammar §6, §7.
- **4.** Core evaluator (`RUNTIME-`): grammar §6, §7; `docs/vm/`. It trusted the
  checker and did not re-check types. Replaced by the bytecode VM in phase 7.
- **5.** CLI and diagnostic quality: grammar §7, §8. The CLI prints the first
  diagnostic to stderr and exits 1; a missing file or bad usage is one plain
  message and exit 2. Every grammar example is a test
  (`tests/test_examples.py`).

Rules from these phases that stay: each stage takes the previous stage's output
and returns data or exactly one diagnostic, stops at the first error, never
prints and never lets a front-end exception escape (also in `AGENTS.md`).
Diagnostic codes are stable and prefixed by stage. Internal checker cases that
should never happen have their own code, `CHECK-INTERNAL`.

**Decisions of this period** (all closed):

- `?` and `!` are part of function names for every function, as in Ruby and
  Elixir (`String.contains?`, `String.to_int!`).
- `Map.has` and `Map.len` became `Map.has_key?` and `Map.size`, with `List.len`
  becoming `List.size` (5c).
- Network and filesystem access use host permissions, with no separate
  capability flag.

## Phases 5b to 5h: the standard library before validation

Names and shapes copy Ruby and Elixir so an agent can guess them: modules called
as `Module.function(...)`, snake_case, `?` for predicates, `!` for the version
that halts. Every function that can fail has two forms: `x(...)` returns
`Result[T]` and `x!(...)` halts with a `RUNTIME-` diagnostic.

- **5b.** Maps and builtin modules: `Map[K, V]` (keys `Int` or `String`,
  insertion order, immutable); `m[k] = v` stays
  `PARSE-INVALID-ASSIGNMENT-TARGET` with a hint to use `Map.put`. Grammar §5,
  §6.
- **5c.** String library:
  [`06b-builtins.md`](../grammar/06b-builtins.md).
- **5d.** Standard input and output (`IO`, `System.args`, `System.exit`, the
  stdio transport primitives): [`06b-builtins.md`](../grammar/06b-builtins.md).
- **5d2.** Consistency fixes: `CHECK-EMPTY-MAP-TYPE`; `--max-steps N` with
  `RUNTIME-STEP-LIMIT`; O(n) list indexing documented (prefer `for`). Grammar
  §4, §6.
- **5d3.** Agent API (partly open): `agentica check <file>` with three printers
  of one structured diagnostic (plain with labels and help, `--ai`, `--json`);
  grounded suggestions only (nearest name, field list, conversion functions,
  missing `return`, habits from Python, Ruby and JavaScript); diagnostics
  counted from evaluation data (`docs/eval.md`).
  [`07-diagnostics.md`](../grammar/07-diagnostics.md).
- **6a.** First agent evaluation: the `agentica-programming` skill, the task set
  and hidden tests in `tests/eval/`, the Agentica and Python arms, the `binary`
  arm and a Firejail sandbox. `docs/eval.md`, `tests/eval/`.
- **5e.** `Result[T]`, `try` and the builtins catalog (the one table of builtin
  names, signatures, effects and descriptions, read by the checker and `agentica
  help NAME --json`, exit 2 for an unknown target): grammar §6,
  [`06b-builtins.md`](../grammar/06b-builtins.md).
- **5f.** JSON: opaque `Json` and the `JSON` module; typed decoding came in 5f2.
  [`06b-builtins.md`](../grammar/06b-builtins.md), skill `references/json.md`.
- **5g.** TCP and TLS: opaque `Socket` and `Listener` handles, full-operation
  deadlines, verified TLS clients and PEM-configured TLS listeners.
  [`06d-io-and-network.md`](../grammar/06d-io-and-network.md),
  `docs/vm/10-io-tls.md`.
- **5h.** HTTP/1.1 and HTTPS: builtin `Header`, `Request`, `Response` and option
  records; client pools, keep-alive, bounded deadlines and body sizes, no
  transparent retries or redirects; verified HTTPS both ways. The builtin `HTTP`
  module was replaced by `std/http` in phase 20.
  [`06d-io-and-network.md`](../grammar/06d-io-and-network.md),
  `docs/vm/10-io-http.md`,
  [`§30.14`](../future/30-hybrid-http.md#3014-implementation-row-74).

**Independent integration fixtures** (the rule that came with 5g and 5h, kept in
`AGENTS.md`): TCP/HTTP interoperability tests use a protocol implementation
independent of the Agentica code under test (Node's `http`, `https`, `net`,
Python's `http.server` and `socket`, or curl), standard libraries only,
localhost, port 0, no external services, with cleanup of processes and ports on
every exit. Fixtures live in `tests/fixtures/`. Local runs may skip with a
visible message when the tool is missing; CI installs Node and must fail rather
than skip. A test against the official MCP SDK needs `npx` and the network, so
it stays manual and out of CI.

## Completed foundations for general programming and MCP

- **5j.** Function values: `Fn[A, ..., R]` (last argument is the return type),
  `&name` for a top-level function, `.call(...)`; exact parameter and return
  matching (`CHECK-TYPE-MISMATCH`). Grammar §6.
- **Executable BDD features:** an English Gherkin subset in `.feature` files,
  `agentica test`, `BDD.run`; moved to `std/bdd` in phase 21.
  [`docs/bdd.md`](../bdd.md), [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md).
- **5j2.** Lightweight I/O concurrency (`Task.spawn`, `Task.await`,
  `Task.sleep`; coroutines, no CPU parallelism): any task diagnostic or
  `System.exit` ends the run; tasks cancelled and new resources closed at
  entry-point return.
  [`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md),
  `docs/vm/10-io-scheduler.md`.
- **5k.** Error propagation: `try` shipped with `Result` in 5e.
- **5n.** Collection primitives (`List.append/set/repeat/reverse`,
  `Map.values/get/delete`): immutable, insertion order; `List` chosen as the
  collection module (no `Enum` beside the `enum` keyword).
  [`06b-builtins.md`](../grammar/06b-builtins.md).
