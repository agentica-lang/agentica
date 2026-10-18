# Roadmap: foundations (phases 1 to 5n, complete)

Phases 1 to 5h and the completed foundations for general programming and MCP.
They were built on the Racket evaluator, which the VM replaced (phase 7, 7i);
the language they define is specified in [`docs/grammar.md`](../grammar.md) and
its files in `docs/grammar/`, and the tests of each stage are in
`tests/test_*.py`. The full checklists and design notes that used to be
of this period are in git history. The current order is in
[`README.md`](README.md).

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

- **Phase:** 1. Source handling and lexer
  - **What landed:** `.agc` text to located tokens or one lexical diagnostic
    (`LEX-`). Positions and spans, tokens, diagnostics; a thin driver
  - **Where:** grammar §4 (history in git)

- **Phase:** 2. AST and parser
  - **What landed:** Tokens to a program (every node carries a span) or the
    first `PARSE-` diagnostic. Nodes hold only data, rules live apart; no
    checker or placeholder nodes for later phases
  - **Where:** grammar §5 (history in git)

- **Phase:** 3. Name resolution and type checking
  - **What landed:** Program to a checked program or the first `CHECK-`
    diagnostic: types, scopes, calls, returns, structs, lists, `Void`/`Nil`
    rules
  - **Where:** grammar §6, §7 (history in git)

- **Phase:** 4. Core evaluator
  - **What landed:** The checked program run to a value or one `RUNTIME-`
    diagnostic; it trusted the checker and did not re-check types. Replaced by
    the bytecode VM in phase 7
  - **Where:** grammar §6, §7; `docs/vm/`

- **Phase:** 5. CLI and diagnostic quality
  - **What landed:** Every diagnostic names file, position, stable code, a
    concrete message and the source line with a caret; the
    CLI prints the first diagnostic to stderr and exits 1; a missing file or bad
    usage is one plain message and exit 2; `--dump` prints the checked tree.
    Every grammar example is a test (`tests/test_examples.py`)
  - **Where:** grammar §7, §8 (history in git)

Rules from these phases that stay: each stage takes the previous stage's output
and returns data or exactly one diagnostic, stops at the first error, never
prints and never lets a front-end exception escape (also in `AGENTS.md`).
Diagnostic codes are stable and prefixed by stage. Internal checker cases that
should never happen have their own code, `CHECK-INTERNAL`. The old
`CHECK-NOT-A-STRUCT` was replaced by `CHECK-UNKNOWN-METHOD`, and the evaluator's
catch-all `RUNTIME-UNREACHABLE` left with the Racket evaluator.

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
`Result[T]` and `x!(...)` halts with a `RUNTIME-` diagnostic. All I/O goes
through injectable ports, so tests do not touch the real network.

- **Phase:** 5b. Maps and builtin modules
  - **What landed:** `Map[K, V]` (keys `Int` or `String`, insertion order,
    immutable), `m[key]`, map literals, qualified calls (`Map.put`,
    `List.size`); `CHECK-MAP-KEY-TYPE`, `RUNTIME-KEY-NOT-FOUND`; `m[k] = v`
    stays `PARSE-INVALID-ASSIGNMENT-TARGET` with a hint to use `Map.put`
  - **Where:** grammar §5, §6

- **Phase:** 5c. String library
  - **What landed:** `String.length`, `upcase`, `downcase`, `trim`, `split`,
    `join`, `contains?`, `starts_with?`, `ends_with?`, `replace`, `slice`,
    `from_int`, `to_int`, `to_float` and the rest of the module
  - **Where:** [`06b-builtins.md`](../grammar/06b-builtins.md)

- **Phase:** 5d. Standard input and output
  - **What landed:** `IO.puts`, `IO.gets`, `IO.read`, `IO.eof?`, `System.args`,
    `System.exit` and the stdio transport primitives (`IO.read_bytes` with a 1
    MiB cap per call and strict UTF-8 decoding, `IO.flush`, `String.from_bytes`)
  - **Where:** [`06b-builtins.md`](../grammar/06b-builtins.md)

- **Phase:** 5d2. Consistency fixes
  - **What landed:** Suffix `?`/`!` recognition apart from call syntax; one NL
    token per LF/CRLF outside delimiters; `CHECK-EMPTY-MAP-TYPE`; `--max-steps
    N` with `RUNTIME-STEP-LIMIT`; O(n) list indexing documented (prefer `for`)
  - **Where:** grammar §4, §6

- **Phase:** 5d3. Agent API (partly open)
  - **What landed:** `agentica check <file>` with three printers of one
    structured diagnostic (plain with labels and help, `--ai`, `--json`);
    optional `expected`, `actual`, `callee`, `labels`, `help` fields; grounded
    suggestions only (nearest name, field list, conversion functions, missing
    `return`, habits from Python, Ruby and JavaScript); diagnostics counted from
    evaluation data (`docs/eval.md`)
  - **Where:** [`07-diagnostics.md`](../grammar/07-diagnostics.md)

- **Phase:** 6a. First agent evaluation
  - **What landed:** The `agentica-programming` skill, the task set and hidden
    tests in `tests/eval/`, the Agentica and Python arms, the `binary` arm and a
    Firejail sandbox; the runner rebuilds `dist/agentica` with `make exe` before
    each round
  - **Where:** `docs/eval.md`, `tests/eval/`

- **Phase:** 5e. `Result[T]`, `try` and the builtins catalog
  - **What landed:** `Result[T]` with `ok`, `error` and the `Result` module
    (`ok?`, `unwrap!`, `unwrap_or`, `message`); `try` in a `Result`-returning
    function (`CHECK-TRY-CONTEXT`); `CHECK-RESULT-TYPE`, `RUNTIME-UNWRAP-ERROR`;
    a builtin catalog as the one table of builtin names, signatures, effects
    and descriptions, read by the checker and `agentica help NAME --json` (exit
    2 for an unknown target)
  - **Where:** grammar §6, [`06b-builtins.md`](../grammar/06b-builtins.md)

- **Phase:** 5f. JSON
  - **What landed:** Opaque `Json` and the `JSON` module (`parse`, `encode`,
    `get`, `at`, `string`, `int`, `float`, `bool`, `list`); `encode` rejects
    `Result` and `Int`-keyed maps at check time and halts on non-finite floats
    (`RUNTIME-JSON-ENCODE`); typed decoding came in 5f2
  - **Where:** [`06b-builtins.md`](../grammar/06b-builtins.md), skill
    `references/json.md`

- **Phase:** 5g. TCP and TLS
  - **What landed:** Opaque `Socket` and `Listener` handles; `TCP.connect`,
    `TCP.listen`, `TCP.accept`, `TCP.send`, `TCP.send_bytes`, `TCP.recv_bytes`,
    `TCP.read_line`, `TCP.close`, `TCP.close_listener` and `TCP.local_port`;
    full-operation deadlines, verified TLS clients and PEM-configured TLS
    listeners
  - **Where:** [`06d-io-and-network.md`](../grammar/06d-io-and-network.md),
    `docs/vm/10-io-tls.md`

- **Phase:** 5h. HTTP/1.1 and HTTPS
  - **What landed:** Builtin `Header`, `Request`, `Response` and option records;
    client pools, keep-alive, bounded deadlines and body sizes, no transparent
    retries or redirects; verified HTTPS both ways. The builtin `HTTP` module
    was replaced by `std/http` in phase 20
  - **Where:** [`06d-io-and-network.md`](../grammar/06d-io-and-network.md),
    `docs/vm/10-io-http.md`, [`20-hybrid-http.md`](20-hybrid-http.md)

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

- **Item:** 5j. Function values
  - **What landed:** `Fn[A, ..., R]` (last argument is the return type), `&name`
    for a top-level function, `.call(...)`; exact parameter and return matching
    (`CHECK-TYPE-MISMATCH`); no closures at that time; `examples/dispatch.agc`
  - **Where:** grammar §6

- **Item:** Executable BDD features
  - **What landed:** An English Gherkin subset in `.feature` files, `agentica
    test`, `BDD.run`, deterministic predefined steps and typed Agentica handlers
    (`BDD.step(..., &handler)`); independent scenarios with fresh state and
    local processes; bounded output and cleanup on all exits. Moved to `std/bdd`
    in phase 21
  - **Where:** [`docs/bdd.md`](../bdd.md),
    [`21-bdd-in-agentica.md`](21-bdd-in-agentica.md)

- **Item:** 5j2. Lightweight I/O concurrency
  - **What landed:** `Task.spawn`, `Task.await`, `Task.sleep` (coroutines, no
    CPU parallelism); typed task results, repeated awaits, a global
    `--max-steps` budget; any task diagnostic or `System.exit` ends the run;
    tasks cancelled and new resources closed at entry-point return. The VM
    scheduler has since replaced the Racket threads
  - **Where:** [`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md),
    `docs/vm/10-io-scheduler.md`

- **Item:** 5k. Error propagation
  - **What landed:** `try` shipped with `Result` in 5e; nothing was left to do
  - **Where:** grammar §6

- **Item:** 5n. Collection primitives
  - **What landed:** `List.append`, `List.set`, `List.repeat`, `List.reverse`,
    `Map.values`, `Map.get` (a `Result` with two arguments, a default with
    three), `Map.delete`; immutable, insertion order, linked-list representation
    kept (O(n) indexing and updates, O(n) `Map.delete`); the knight tour,
    traveling salesman and maze BFS examples with functional tests; `List`
    chosen as the collection module (no `Enum` beside the `enum` keyword)
  - **Where:** [`06b-builtins.md`](../grammar/06b-builtins.md)
