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
  ast.rkt         # syntax tree nodes; every node carries a span
  parser.rkt      # parse: (listof token) -> program | diagnostic
  builtins.rkt    # shared signatures, type-rule tags, dispatch keys, effects, descriptions
  checker.rkt     # check: program -> program | diagnostic
  evaluator.rkt   # evaluate: program -> 'nil | diagnostic (RUNTIME-); puts writes to current-output-port
  json.rkt        # opaque Json wrapper and strict input guard around Racket read-json
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

- `Json` is opaque, not primitive for equality. Reserve `Json` and `JSON`; all calls use existing parser/AST forms. The catalog has nine JSON functions; `json-encode` is the only new generic checker rule.
- Recursively check encoding eligibility, including declared struct fields and empty containers. A seen-struct path prevents infinite recursion without skipping other fields. Results and Int-keyed maps are CHECK-NOT-ENCODABLE.
- `src/json.rkt` delegates parsing to bundled `read-json`. Use direct character checks for raw controls and trailing JSON whitespace. Racket CS 9.3 accepts raw controls in strings and can raise a non-read exception for malformed exponents such as `0.0001e+`; the evaluator catches parsing failures locally as Results, never around argument evaluation.
- False/null are present values. Int extraction is signed 64-bit and rejects decimal/exponent forms; Float extraction permits integer conversion only if finite. Parse rejects non-finite numbers, while large integer Json payloads remain valid.
- Encoding stays beside runtime values in evaluator.rkt; write objects in stored map/declared field order and use write-json for scalar escaping. Non-finite Floats halt with RUNTIME-JSON-ENCODE at the call span. Debug output is `<Json>`, not the host contents. Decoding/builders/schemas remain later phases.

## Collections and algorithm examples (phase 5n, primitive operations)

- `List.append`, `set`, `repeat`, and `reverse` preserve inputs and use the existing Racket lists. Indexing and updates remain O(n); repeat is capped at 1048576 and reports RUNTIME-INVALID-COUNT at the count argument. List.set uses the existing index diagnostic at the index argument.
- Catalog entries have an automatic alternatives field. Only catalog initialization fills it; builtin-ref optionally selects by arity. Map.get has two signatures: Result[V] with two arguments, V with an eagerly evaluated default with three. Text help lists both; its JSON help has an overloads array, while existing single-signature help stays unchanged. Do not add user-function overloading.
- Generic rules propagate expected types into list construction/updates and Map.get. Keep false/nil lookup payloads distinct from absent keys. Map.delete updates both the hash and insertion-order keys; reinsertion goes last. Map.values follows Map.keys order.
- `examples/knight-tour.agc` uses degree-ordered backtracking for open tours, sizes 1..8. `examples/traveling-salesman.agc` searches optimal directed circuits over 1..8 cities with nonnegative bounded Int weights. The examples tests validate complete routes and known optimal costs with a 5000000-step budget. A runtime limit is not an unsolvable-result signal.
- Callback operations remain pending in 5n and require 5j; these primitive operations do not. Grammar and programming reference are kept together; stages.md includes the catalog arity contract.

## Reference

Read `references/stages.md` for the full token-kind table, the diagnostic-code list, the AST node list, and each module's public API. Load it when adding or renaming tokens, AST nodes, or diagnostic codes.
