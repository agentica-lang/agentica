---
name: agentica-development
description: "Develops the Agentica interpreter in Racket: where each pipeline stage lives, how to add tokens, AST nodes, syntax, diagnostics, and tests, plus the Racket and lexer gotchas specific to this repo. Use when working in the agentica Racket repository on src/, tests/, the lexer, parser, AST, diagnostics, or CI. Don't use for the grammar or roadmap documents alone, or for other Racket projects."
---

# Agentica development

Agentica is a Racket bootstrap for a small statically typed language. The grammar is `docs/grammar.md`; planned syntax is in `docs/future.md`; the phases and the active checklist are `docs/roadmap.md`.

Read the active phase in the roadmap before adding code. Implement only what that phase asks for: the roadmap explicitly forbids placeholder modules and empty nodes for later phases.

## Commands

Run all of these before calling a change done:

```sh
make test                                 # every stage test, in parallel
make test TESTS="tests/lexer-test.rkt"    # one stage while iterating
racket src/main.rkt examples/hello.agc    # CLI smoke test; exits 0 on success
racket src/main.rkt --json check examples/result.agc
racket src/main.rkt examples/classify.agc
racket src/main.rkt examples/tasks.agc
racket src/main.rkt examples/inventory.agc
racket src/main.rkt examples/strings.agc
racket src/main.rkt examples/result.agc
racket src/main.rkt examples/json.agc
```

CI (`.github/workflows/ci.yml`) runs exactly these on Racket CS 9.3. Use the standard library only; the project adds no dependencies.

## Repository map

```text
src/
  source.rkt      # source, source-position, source-span (span end is exclusive)
  diagnostic.rkt  # diagnostic struct and format-diagnostic
  token.rkt       # token struct
  lexer.rkt       # lex: source -> (listof token) | diagnostic
  ast.rkt         # syntax tree nodes (including enums and case patterns); every node carries a span
  parser.rkt      # parse: (listof token) -> program | diagnostic
  builtins.rkt    # shared signatures, type-rule tags, dispatch keys, effects, descriptions
  checker.rkt     # check: program -> program | diagnostic
  evaluator.rkt   # evaluate: program -> 'nil | diagnostic (RUNTIME-); puts writes to current-output-port
  runtime-values.rkt # shared runtime values, results and immutable map updates
  task.rkt        # coroutine task results, supervision, global budget and cleanup
  json.rkt        # opaque Json wrapper and strict input guard around Racket read-json
  gherkin.rkt     # English feature parser, expansion and source locations
  bdd.rkt         # scenario context, assertions and supervised local process streams
  bdd-runner.rkt  # deterministic step registration/resolution, execution and reports
  main.rkt        # thin CLI driver: lex, parse, check, then run (or `check` only, or --dump the tree); exit 1 on a diagnostic, 2 on usage or a missing file
tests/
  lexer-test.rkt
  parser-test.rkt
  checker-test.rkt
  evaluator-test.rkt
  diagnostic-test.rkt   # excerpt and caret format
  examples-test.rkt     # examples/*.agc, rejected fragments, CLI exit codes
examples/               # hello.agc, classify.agc, tasks.agc, inventory.agc, strings.agc, echo.agc, result.agc, json.agc
docs/
  grammar.md   # language grammar, the source of truth
  future.md    # planned syntax, not implemented
  roadmap.md   # phases and the active checklist
```

## Where new code goes

| Add | Location |
| --- | --- |
| keyword, operator, or literal form | `src/lexer.rkt` lookup tables |
| AST node | `src/ast.rkt` struct plus `provide`; construct it from `src/parser.rkt` |
| syntax, statement, or expression form | `src/parser.rkt` |
| builtin | `src/builtins.rkt` metadata; checker generic rule and evaluator implementation; exercise a real checked call |
| diagnostic code | raise it where the problem is detected; prefix by stage (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`) |
| pipeline stage | new `src/<stage>.rkt`, wired into `src/main.rkt`, tested by `tests/<stage>-test.rkt` |
| language rule or example | `docs/grammar.md`; phase scope in `docs/roadmap.md`; also update `.agents/skills/agentica-programming/references/language.md` (the reference evaluators read instead of the grammar) |
| test | `tests/<stage>-test.rkt` |

## Stage contract

Every stage follows the same shape; keep new stages consistent with it.

- Entry point is one function: `(lex input)`, `(parse tokens)`, later `(check program)`, `(evaluate program)`.
- Return either the next data or a single `diagnostic`. Stop at the first error; do not collect several.
- Never print and never raise from a stage. `main.rkt` owns presentation and exit codes.
- `main.rkt` guards with `diagnostic?` between stages, prints `format-diagnostic` on stderr, and exits 1.
- Thread spans through everything so diagnostics point at the source.

## Common tasks

### Add a keyword or operator

1. Add it to the `keywords` hash (reserved words) or the operator hash in `src/lexer.rkt`.
2. If the parser must act on it, add the kind to the relevant `case`/`memq` in `src/parser.rkt`.
3. Add a test in `tests/lexer-test.rkt` (kinds) and, when it affects syntax, `tests/parser-test.rkt`.
4. Run `raco test tests/`.

### Add an AST node

1. Add a `#:transparent` struct in `src/ast.rkt` with `span` as the last field, and add `(struct-out <node>)` to `provide`.
2. Construct it in `src/parser.rkt` and set the span from the first token to the last consumed token (the existing `span-from` helper).
3. Test the node's fields and its span line/column.

### Add syntax

1. Add tokens first if the syntax needs them.
2. Add the AST node if no existing node fits.
3. Write a parse function and call it from the right place: `parse-statement` for statements, `parse-primary` for expressions, `parse-program` for declarations.
4. Add one valid test and one rejection test asserting the diagnostic code.
5. Run `raco test tests/` and the smoke test.

### Add a diagnostic code

1. Choose the stage prefix: `LEX-`, `PARSE-`, later `CHECK-` or `RUNTIME-`.
2. Raise it with the stage's `bail`/`fail` helper and a token or position span.
3. Test both the code and the location (`source-position-line`/`-column` of the diagnostic span), as `tests/parser-test.rkt` does.

### Add a pipeline stage

1. Create `src/<stage>.rkt` with one entry point and a `provide`.
2. Require the previous stage's data modules only; do not reach back into the CLI.
3. Wire it into `src/main.rkt` after the previous stage, behind a `diagnostic?` guard.
4. Add `tests/<stage>-test.rkt`. `raco test tests/` discovers it automatically; CI needs no change.

### Add tests

- Use `#lang racket`, `rackunit`, and `module+ test` with `test-case` blocks.
- Require sources with relative paths (`"../src/lexer.rkt"`); they resolve from the test file.
- Keep the small helpers pattern from `tests/parser-test.rkt`: `parse-ok` fails loudly when a valid input returns a diagnostic, and `parse-code` returns the code or fails when invalid input parses.
- Cover the happy path, the error path, and the specific behavior the change introduces.

## Racket gotchas

- `define` is not allowed in an expression context, and `(begin ...)` is an expression. `(begin (define x 1) ...)` fails with `define: not allowed in an expression context`. Use `(let () ...)` to open a body that allows internal defines. `cond`/`case` clause bodies, `let/ec` bodies, and lambda bodies already allow them.
- `define` binds like `letrec`. A local named the same as the accessor it calls, such as `(define param-type (param-type x))`, fails with `undefined; cannot use before initialization`. Name locals distinctly.
- `source` is opaque (no `#:transparent`), so printing a tree shows `#<source>` instead of repeating the file text; every other struct is `#:transparent`. Keep any struct that holds the whole source text opaque.
- The lexer and parser are single mutable-pass scanners driven by `set!`. The parser cursor is capped at the last token (`EOF`), so `advance!` never runs past the end and `current`/`peek-token` stay safe at EOF.
- Early exit uses `let/ec` with a `bail`/`return` helper that escapes with a `diagnostic`. This is how a stage stops at the first error.
- `provide (struct-out name)` exports the constructor, predicate, and accessors in one line.
- `#lang racket` provides `pretty-print`; `src/main.rkt` uses it for `--dump`.
- `unary` and `binary` carry `op-span` (the operator token) beside `span`. Operator diagnostics use `op-span`; `node-span` in `ast.rkt` returns any node's span.
- Racket `equal?` treats `+nan.0` as equal to itself and `0.0` unequal to `-0.0`; the evaluator compares numbers with `=` so `==` follows IEEE 754.
- Positions count Racket string characters, line and column are 1-based, and span ends are exclusive. Keep that convention in new spans.

## Lexer gotcha: stray NL tokens

The lexer emits one `NL` per LF/CRLF outside `()`, `[]`, and `{}`, including every blank/comment line, so extra lines between statements can leave more than one `NL` token. The grammar's `program` and `block` rules do not model this. The parser therefore skips stray `NL` at the top level and between statements. Keep that skip when adding statement forms, or valid files with comments between statements will fail to parse.

## Error handling

- `raco test tests/` failure: read the failing `test-case` name and the message from the `parse-ok`/`parse-code` helper. A `parse-ok` failure prints the diagnostic the stage returned.
- Smoke test exits 1: `main.rkt` printed `file:line:column error[CODE]`, the message, and a source excerpt with a caret on stderr. That is a stage diagnostic, not a crash.
- A Racket traceback instead of a diagnostic means a stage raised or indexed out of range. Find the token or index and turn it into a `bail`/`fail`; the roadmap requires Agentica diagnostics, never host tracebacks.
- A stage unexpectedly returns a diagnostic: check the first-error rule and that `main.rkt` guards with `diagnostic?` before passing data to the next stage.

## Result, propagation, and runtime bounds

- `Result[T]` is builtin, with String errors and contextual `ok`/`error` typing. Forward expected types through the shared call path; do not add global inference or dummy payload types. Untyped errors are `CHECK-RESULT-TYPE`.
- `try` is a unary expression node. It requires a Result-returning function (`CHECK-TRY-CONTEXT` otherwise), unwraps successes, and returns errors through the current function's escape, not the evaluator's diagnostic escape. It does not guarantee a return.
- IO.gets now returns Result[String]; IO.gets! is the old String-returning/halting form. Migrate callers in tests/eval/tasks as well as examples, without repairing intentional starter bugs or changing hidden cases. Non-bang conversions recover only their documented failures.
- Function suffixes allow whitespace before `(`; `!=` remains an operator. Empty map inference uses `CHECK-EMPTY-MAP-TYPE`.
- `evaluate` accepts optional `#:max-steps` (positive integer or #f). Count every expression/statement entry, including loop conditions; reset per run. CLI --max-steps validates the input; check never executes. This is not a blocking-I/O timeout.
- A rebase changing AST/diagnostic layouts may leave stale ignored Racket bytecode. For an instantiate-linklet struct mismatch, use `make clean && make build && make test`; rebuild the binary with make exe before evaluation.

## Stdio bytes and flushing

- `IO.read()` remains the all-text-until-EOF API. `IO.read_bytes(count)` uses native read-bytes and returns Result[List[Int]]; wait for count bytes or EOF, return short/empty success at EOF, and do not consume input for zero or invalid counts. The fixed 1 MiB per-call cap prevents eager allocations from arbitrary Int sizes; larger streams use repeated reads. Port read failures are local Results, not exceptions around argument evaluation.
- `String.from_bytes` uses byte? validation, list->bytes, and bytes->string/utf-8 with #f for strict decoding. Invalid byte values and malformed/incomplete UTF-8 return Result errors. No Bytes type or new checker rule is needed: these are fixed catalog signatures.
- EOF uses peek-byte, not peek-char: a peer may have sent only the leading UTF-8 byte. EOF peeking still blocks if there is no data, so it is not a readiness poll. Text and byte reads share the port; switch to text only at complete character boundaries.
- `IO.flush` flushes current-output-port and returns nil. Do not auto-flush other output functions or close ports. The live Racket CLI pipe test with stdin held open protects response delivery and byte-oriented EOF peeking; it fails if flushing becomes a no-op or EOF reverts to peek-char. All blocking stdio calls remain without timeouts.

## JSON (phase 5f)

- Typed decoding (5f2) uses a type-expression AST node accepted only in JSON type argument positions. json-typed.rkt walks checker-validated declarations into existing runtime instances/mappings; JSON.decode returns located-path Result errors for bad data, validates signed Int/finite Float bounds, and ignores extra fields. Recursive type validation visits each struct once. Decoded map keys are sorted. JSON.schema uses the same eligibility check, emits required fields/64-bit bounds and $defs/$ref for nested or recursive types. Builders construct opaque Json directly; JSON.from shares encode eligibility and non-finite diagnostics. Builtin record declarations participate in decoding and schemas.

- `Json` is opaque, not primitive for equality. Reserve `Json` and `JSON`; all calls use existing parser/AST forms. The catalog has nine JSON functions; `json-encode` is the only new generic checker rule.
- Recursively check encoding eligibility, including declared struct fields and empty containers. A seen-struct path prevents infinite recursion without skipping other fields. Results and Int-keyed maps are CHECK-NOT-ENCODABLE.
- `src/json.rkt` delegates parsing to bundled `read-json`. Use direct character checks for raw controls and trailing JSON whitespace. Racket CS 9.3 accepts raw controls in strings and can raise a non-read exception for malformed exponents such as `0.0001e+`; the evaluator catches parsing failures locally as Results, never around argument evaluation.
- False/null are present values. Int extraction is signed 64-bit and rejects decimal/exponent forms; Float extraction permits integer conversion only if finite. Parse rejects non-finite numbers, while large integer Json payloads remain valid.
- Encoding stays beside runtime values in evaluator.rkt; write objects in stored map/declared field order and use write-json for scalar escaping. Non-finite Floats halt with RUNTIME-JSON-ENCODE at the call span. Debug output is `<Json>`, not the host contents. Decoding/builders/schemas remain later phases.

## Collections and algorithm examples (phase 5n, primitive operations)

- `List.map/filter/reduce` infer input element types from exact callback signatures, including empty lists. Reduce is a left fold with accumulator first; its callback result must equal its accumulator type and supplies context for the initial value. Map rejects Void results. Evaluator callbacks use local call-function, preserving scopes, depth, diagnostics and the shared step budget; do not call public evaluate. Traversals preserve inputs and order and cost O(n) excluding callback work.
- `List.sort/sort_by` use one shared `order<?` in evaluator.rkt (string<? by code point, NaN last) with Racket's stable `sort`. The checker allows only Int, Float or String elements/keys. sort_by calls the key once per element through call-function, then sorts the cached keys; the key callback's parameter type types an empty input list.
- String search and conversion builtins: index_of uses regexp-quote and returns character positions (empty part is ok(0)); at/code/from_code report errors at the argument span; from_code rejects surrogates. Float.to_int/to_int! share `fallible`: NaN/infinity give RUNTIME-INVALID-NUMBER, out-of-range truncation RUNTIME-INTEGER-OVERFLOW. `Float` works as a builtin module prefix because catalog names are full dotted strings.
- `List.concat/take/drop/at` are implemented through the catalog and generic checker. Concat propagates expected types and can infer an empty first list from the second. Take/drop accept all nonnegative Int counts, clamp to length, and report RUNTIME-INVALID-COUNT at negative counts. At propagates the expected element type and reuses RUNTIME-INDEX-OUT-OF-RANGE at the index argument. Inputs stay immutable; concat costs O(length of first list), and take/drop/at are O(n).
- `List.append`, `set`, `repeat`, and `reverse` preserve inputs and use the existing Racket lists. Indexing and updates remain O(n); repeat is capped at 1048576 and reports RUNTIME-INVALID-COUNT at the count argument. List.set uses the existing index diagnostic at the index argument.
- Catalog entries have an automatic alternatives field. Only catalog initialization fills it; builtin-ref optionally selects by arity. Map.get has two signatures: Result[V] with two arguments, V with an eagerly evaluated default with three. Text help lists both; its JSON help has an overloads array, while existing single-signature help stays unchanged. Do not add user-function overloading.
- Generic rules propagate expected types into list construction/updates and Map.get. Keep false/nil lookup payloads distinct from absent keys. Map.delete updates both the hash and insertion-order keys; reinsertion goes last. Map.values follows Map.keys order.
- `examples/knight-tour.agc` uses degree-ordered backtracking for open tours, sizes 1..8. `examples/traveling-salesman.agc` searches optimal directed circuits over 1..8 cities with nonnegative bounded Int weights. The examples tests validate complete routes and known optimal costs with a 5000000-step budget. A runtime limit is not an unsolvable-result signal.
- Callback operations remain pending in 5n and require 5j; these primitive operations do not. Grammar and programming reference are kept together; stages.md includes the catalog arity contract.
- `examples/maze-bfs.agc` demonstrates Map.get/2 for discovery, Map.get/3 for passable cells, and Map.delete for a numeric-keyed FIFO queue. Rectangular grids are capped at 32×32; tests check legal shortest paths and distinguish invalid input from an unreachable goal. Queue deletion is O(n), so do not claim linear runtime from BFS alone.

## File modules

- modules.rkt links parsed files before checking: canonical paths deduplicate imports and detect cycles; aliases resolve only exported declarations. Dependencies get unique internal identities while root names remain stable for CLI/BDD entrypoints. Preserve every original span when rewriting nodes; never restart evaluation for imported calls/tasks. Imports resolve relative to their source, not cwd. Alias/declaration collisions and builtin-name redefinitions are rejected before renaming. as is contextual, import/export are keywords.
- CLI check/run/dump and BDD handler loading share this resolver. Raw import/export nodes passed directly to check give CHECK-MODULE-CONTEXT. Exported signatures may mention private types; importers cannot name/construct those types. `std/` reads compile-time embedded Agentica sources from stdlib.rkt, with virtual source names and no filesystem fallback. Add shipped modules to its explicit registry; embed-source tracks external source dependencies with register-external-file. `pkg/` searches entrypoint-local agc_libs, absolute AGENTICA_PATH roots, user data and Unix system data; first existing file wins. Skip missing candidates before normalize-path (it fails for absent parent directories); validate namespace components and canonical symlink containment. Other paths remain source-relative. No package registry, wildcard imports, module state, cycles, or receiver attachment.
- tests/modules-test.rkt owns linking/visibility, cross-file diagnostics, shared task budgets, BDD imports, and the combined JSON example. Its CLI test honors AGENTICA_TEST_EXECUTABLE for compiled CI coverage. Unknown dotted calls without a matching import alias pass to the checker so misspelled builtin calls retain CHECK-UNKNOWN-NAME; unknown qualified type aliases remain CHECK-IMPORT-NAME.

## Enums and pattern matching

- `enum-decl` and `enum-variant` live in `ast.rkt`; `case-stmt`, `case-arm`, `wildcard-pattern`, `literal-pattern`, `variant-pattern`, and `enum-constructor` are the matching nodes. The parser maps `true`/`false`/`nil` patterns to `#t`/`#f`/`'nil`, just like expression literals. `_` in a payload slot is represented by `#f` in the bindings list; it never introduces a variable.
- Generic type variables exist only while resolving an enum's payload declarations. Preserve those names while the module linker rewrites type references; otherwise `T` becomes a module-qualified ordinary type and generic enum registration fails. Imported enum references resolve `Alias.Enum`; variants need `Alias.Enum.Variant`.
- Nullary enum construction with `Option.None()` is parsed as a general `construct` node (empty argument list); module linking/checking/evaluation must recognize the enum prefix. Payload variants parse as `enum-constructor`. Imported nullary calls have three segments and must be rewritten before ordinary struct constructor resolution.
- Checker enum types are nominal and retain their enum name plus resolved type arguments. Infer type variables structurally from payload types and seed inference from a matching expected enum type. `Result[T]` is still the builtin Result, but case patterns use tags `Result.Ok` and `Result.Err`; `Result[Void]` can only discard its Ok payload with `_`.
- Enum cases require every variant or `_`. All non-enum scrutinees—including Bool and Nil—require `_`. Reject repeated/covered arms, require `_` last, and validate pattern payload arity/types before checking each arm in a fresh scope. Exhaustive case branches participate in all-path return analysis.
- Runtime enums use a tagged `enum-value` carrying canonical enum name, variant name, and payload list. Result values remain `result-ok`/`result-error`; matching adapts those runtime values to the Result variant tags. Keep the independent module-linker tests for exported/private enums and imported patterns.
- Stable checker diagnostics include `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`, `CHECK-ENUM-TYPE-INFERENCE`, `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`, and `CHECK-UNREACHABLE-CASE-ARM`; tests should assert codes, not wording.

## Function values and BDD

- `&name` creates a named `function-value`; `Fn[A, ..., R]` uses the final argument as return type, and `.call(...)` is a dedicated invoke AST node. Resolve only declared functions; no closures, builtin references, function equality or JSON encoding. Inspect is `<Fn>`.
- BDD specs are `.feature`, not `.agc` scenario registrations. Keep the Gherkin parser separate from the language parser; it returns one PARSE-GHERKIN diagnostic with a span. English subset only, with Background replay and independent outline rows. Reject unsupported syntax instead of omitting it.
- The catalog contains BDD signatures; evaluator dispatch delegates to its `#:builtin-handler` service. The CLI installs `make-bdd-service`; the runner installs registration/scenario handlers, avoiding a runner/evaluator import cycle. `#:entrypoint` and `#:arguments` invoke checked callbacks with fresh scopes.
- `BDD.step` takes `Fn[List[String], Void]`. Resolve all step text before any scenario actions; duplicate patterns, undefined steps, or ambiguous matches fail. Then/And/But must increase the BDD assertion count; early System.exit never approves a step. JSON state belongs to one scenario.
- `BDD.run` returns Result[Json]: Result success means evaluation completed, while report `ok` is the verdict. Normalize report JSON null to the evaluator's `'nil` representation before wrapping it. CLI `test` enforces exit_code and prints reports only; suppress/bound handler output.
- Programs under test run directly on the host with inherited environment and permissions, using the current compiled Agentica executable or Racket and src/main.rkt for source execution. The feature directory is their working directory. Scenario custodians own processes and stream workers; cleanup kills and reaps processes. Drain available bytes, not fixed-size reads that wait for a full buffer or EOF.
- `make test` compiles the CLI and its modules before starting parallel Racket test workers, then includes local process integration tests with no opt-in or image preparation; JOBS controls workers. Source subprocess startup otherwise recompiles modules in a clean checkout and can exhaust BDD response deadlines. `make test-bdd` builds and verifies the compiled CLI against the feature suite. Negative no-flush tests, exact stream/exit checks and blocked-process cleanup protect supervision; CI runs both commands.

## Lightweight I/O tasks

- Task.spawn takes Fn[A, R] and one argument and returns Task[R]; await returns the cached R, including false/nil/error Results. Sleep takes nonnegative milliseconds, zero yields and negative values halt with RUNTIME-INVALID-DURATION. Reserve Task; use Todo for the demonstration struct. No channels, closures or CPU parallelism.
- Build immutable program tables once per evaluate. Each evaluate-with-ports invocation has independent scopes, depth, returns and diagnostic escapes. Spawn calls that worker with the same execution; calling public evaluate would reset supervision and budget.
- task.rkt supervises main and children outside their run custodian. Any diagnostic or System.exit publishes a terminal outcome and interrupts even blocked main I/O. First publication wins. The shared step counter is synchronized; completed handles leave the active registry but retain cached results.
- Entrypoint return cancels pending work. A watcher also cleans up if the supervisor is killed without dynamic-wind cleanup. Newly created resources close; borrowed ports remain open. Tasks inherit ports, arguments and services; cross-task stream ordering is unspecified.
- BDD passes require-complete-tasks? to evaluate; pending work fails with RUNTIME-BDD-PENDING-TASKS. Timed-operation custodians nest under their caller, and the outer guard nests under the scenario custodian, so cancellation covers nested I/O workers.
- Synchronize BDD registration/state/assertions and quiet-output counters. Separate stdin and stdout locks, include lock wait in deadlines, serialize startup and reject streams until startup completes. Never hold the state lock around blocking I/O.
- tests/task-test.rkt owns checked-program task behavior with injected ports/events. BDD tests own contextual behavior; tests/bdd-integration.rkt verifies real concurrent local streams and cleanup. examples/concurrency.agc is a hermetic CI smoke check.

## TCP, TLS and HTTP/1.1

- network.rkt owns sockets/listeners, secure TLS contexts and full-operation deadlines. Resource custodians are distinct from temporary timeout workers, so failure during DNS/connect/handshake cannot leak ports. Force custodian shutdown before closing ports to avoid a blocking flush during cleanup. Read and write locks are independent; timing out lock acquisition alone preserves the other task's socket.
- builtin-types.rkt centralizes opaque atoms and builtin record field layouts. Seed checker structs and evaluator field order from it; generic HTTP upload callbacks infer their context argument. Handles cannot be constructed, compared or JSON encoded. Grammar and the programming reference describe the same public API.
- http-wire.rkt owns strict HTTP/1.1 framing, bounded headers, fixed/chunked/EOF bodies, trailers, HEAD/no-body responses, writer states and flushing. Headers use ordered Header records; preserve duplicates. Framing headers and Host are managed by the transport. Reject ambiguous framing and CR/LF injection.
- http-client.rkt pools by origin with bounded connections and idle expiry. Release a lease only after both upload and response finish. Abort unread or invalid bodies. Upload producers run as supervised tasks concurrently with response reception; Result errors remain recoverable, diagnostics retain their source location. No transparent retries or redirects.
- Track a pending connection custodian before DNS/connect/TLS begins. Request abort must shut it down before releasing the pool reservation; only clear it after handing the socket to the lease. Nested timeout workers otherwise survive the outer deadline because they belong to the client custodian.
- http-server.rkt uses one supervised task per connection and fresh evaluator invocations for handlers. TLS handshakes occur after acceptance in connection tasks. Requests are sequential on each connection. Close cancels all owned tasks synchronously; connection completion also cancels nested work. Do not call public evaluate from a callback: it would reset the global budget and supervision.
- task-spawn accepts an internal custodian; task-shutdown! finalizes dead tasks and removes them from the pending registry. Awaiting cancelled work yields RUNTIME-TASK-CANCELLED. Intentional resource cancellation does not publish a global failure. Watchers still cover kill-thread bypassing dynamic-wind.
- tests/tcp-test.rkt and tests/http-test.rkt use independent Node standard-library peers in tests/fixtures/network-peer.js. CI installs Node 24; absence fails CI and visibly skips locally. Checked-in localhost test certificates exercise trusted TLS, untrusted certificates and hostname rejection. CLI checks prove progressive uploads/responses and connection reuse; task-test owns budget/diagnostic/cleanup boundaries.

## Files and paths

- filesystem.rkt owns file handles, bounded text/byte operations, directory functions and lexical path functions. Handles carry the evaluation owner and a custodian; evaluator.rkt supplies both through parameters so run cancellation closes open ports. File reads/writes serialize on one per-handle lock, include lock wait in the deadline, and close the handle only when active I/O times out. Symlink targets resolve relative to the link's own directory, and link cycles stop at the first repeated path. Cleanup waits briefly for a contended handle lock before flushing and closing, so a finishing task's buffered output is not dropped.
- File.open accepts read/write/append modes and only regular files or links to regular files. Whole-text calls and individual stream operations cap data at 1 MiB; strict UTF-8 errors become Result errors. Dir.mkdir is recursive and idempotent, Dir.list is sorted, and Path.resolve is lexical without symlink resolution. builtin-types.rkt owns FileHandle and FileInfo registration; grammar.md and the self-contained programming reference document matching semantics.
- tests/filesystem-test.rkt exercises checked Agentica programs against temporary directories, including stream/whole-file round trips, error Results, metadata, paths and EOF. Keep filesystem tests local and clean temporary trees on every outcome.

## Void and processes

- Void completes a function without data. Only return/Fn-result/Result/Task completion positions accept it; reject inferred Void values except statements and forwarded Void returns. Nil remains data and requires explicit returns. Main and side-effect callbacks return Void. Result[Void] success uses ok(); the evaluator uses Racket void internally, including cached Task[Void] results. Migrate fixtures by meaning, preserving Nil and false data cases.
- process.rkt owns children, literal argv launching, fixed-buffer stderr forwarding, independent timed read/write locks, and an evaluation registry. Register pending spawns before launching; kill and reap children on explicit close and all evaluation outcomes. Remove closed and failed-spawn handles from the registry after cleanup, using the registry and lock stored on the handle because supervisor cleanup does not inherit evaluation parameters. Active stream timeouts abort; lock and exit-wait timeouts preserve children. Per-call limits are 1 MiB; stdout needs concurrent reads when waiting could fill its pipe.
- --allow-run defaults off. evaluate inherits an explicit enclosing allowance for services, and the CLI supplies its flag. run-bdd propagates it to handlers and native children. task.rkt's watcher performs cleanup once on normal completion or supervisor death, then shuts down the run custodian; borrowed ports stay open. Context/cleanup failures have located diagnostics; expected operations return Results.
- tests/process-test.rkt uses independent Node standard-library children, CLI capability checks, binary/full-duplex streams, nonzero exits, deadline policies and PID cleanup. Node is required in CI; local absence visibly skips. CI also exercises the compiled executable and examples/process-tool.agc with --allow-run.

## Releases

- `src/version.rkt` is the single source of the version: `make version` prints it and `agentica --version` reports it. Keep it in sync with `CHANGELOG.md` and the Git tag.
- `CHANGELOG.md` follows Keep a Changelog and Semantic Versioning. Add user-visible entries under `## [Unreleased]` as work lands, and move them into a dated version section when tagging.
- Tag releases with the bare version (`0.1.0`, no `v` prefix). `.github/workflows/release.yml` validates the tag against `src/version.rkt`, builds `dist/agentica`, packages a `raco distribute` bundle, and publishes a GitHub Release with generated notes.

## Reference

Read `references/stages.md` for the full token-kind table, the diagnostic-code list, the AST node list, and each module's public API. Load it when adding or renaming tokens, AST nodes, or diagnostic codes.
