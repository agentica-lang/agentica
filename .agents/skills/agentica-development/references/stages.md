# Pipeline stages reference

Detailed tables for the Agentica Racket sources. Read this when adding or renaming a token, AST node, or diagnostic code.

## Conventions

- A span end is exclusive; offsets count Racket string characters; line and column are 1-based.
- Every stage is `(stage input) -> data | diagnostic`, stops at the first error, and never prints.
- `format-diagnostic` renders a located header, message, source marks/labels, and grounded help. AI and JSON printers consume the same diagnostic data.

## `src/source.rkt`

| Struct | Fields |
| --- | --- |
| `source` | `name`, `text` (opaque) |
| `source-position` | `offset`, `line`, `column` |
| `source-span` | `source`, `start`, `end` |

Accessors: `source-name`, `source-text`, `source-position-offset`/`-line`/`-column`, `source-span-source`/`-start`/`-end`.

## `src/token.rkt`

`(struct token (kind lexeme value span))`. `kind` is a symbol; `lexeme` is the source text; `value` is the decoded literal or `#f`; `span` is a `source-span`.

### Token kinds

| Kind | Lexeme |
| --- | --- |
| `name` | identifier starting with a lowercase letter or `_` |
| `type-name` | identifier starting with an uppercase letter |
| `def` `struct` `end` `if` `elsif` `else` `while` `for` `in` `return` `try` `true` `false` `nil` `and` `or` `not` | the reserved words |
| `integer` `float` | decimal number literal |
| `string` | decoded string contents |
| `arrow` `equal` `not-equal` `less-equal` `greater-equal` | `->` `==` `!=` `<=` `>=` |
| `left-paren` `right-paren` `left-bracket` `right-bracket` `left-brace` `right-brace` | `(` `)` `[` `]` `{` `}` |
| `comma` `colon` `dot` | `,` `:` `.` |
| `assign` `plus` `minus` `multiply` `divide` `modulo` `less` `greater` | `=` `+` `-` `*` `/` `%` `<` `>` |
| `NL` `EOF` | newline token, end of input |

The parser reads the keyword literals from their kind, not from `value`: `true` → `#t`, `false` → `#f`, `nil` → the symbol `'nil`.

## `src/diagnostic.rkt`

`(diagnostic code message span #:expected #:actual #:callee #:signature #:labels #:help)` constructs a structured diagnostic with optional fields. `format-diagnostic`, `format-diagnostic-ai`, and `diagnostic->jsexpr` present the same data.

| Stage | Codes |
| --- | --- |
| lexer | `LEX-UNEXPECTED-CHAR`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE` |
| parser | `PARSE-UNEXPECTED-TOKEN`, `PARSE-UNCLOSED-BLOCK`, `PARSE-TOP-LEVEL-STATEMENT`, `PARSE-CHAINED-COMPARISON`, `PARSE-INVALID-ASSIGNMENT-TARGET` |
| checker | `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-REDEFINED-NAME`, `CHECK-ARITY`, `CHECK-TYPE-MISMATCH`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`, `CHECK-RESULT-TYPE`, `CHECK-TRY-CONTEXT`, `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`, `CHECK-MISSING-FIELD`, `CHECK-NOT-A-STRUCT`, `CHECK-NOT-A-LIST`, `CHECK-NOT-INDEXABLE`, `CHECK-MAP-KEY-TYPE`, `CHECK-NOT-ENCODABLE`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING`, `CHECK-IMMUTABLE-ASSIGNMENT`, `CHECK-MISSING-RETURN`, `CHECK-MAIN`, `CHECK-INT-RANGE`, `CHECK-INTERNAL` |
| evaluator | `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`, `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND`, `RUNTIME-INVALID-NUMBER`, `RUNTIME-END-OF-INPUT`, `RUNTIME-UNWRAP-ERROR`, `RUNTIME-JSON-ENCODE`, `RUNTIME-STEP-LIMIT`, `RUNTIME-STACK-OVERFLOW`, `RUNTIME-UNREACHABLE`, `RUNTIME-INTERNAL` |

## `src/lexer.rkt`

`(lex input) -> (listof token) | diagnostic`. One pass over the source:

- CRLF normalizes to one newline; a lone carriage return is `LEX-UNEXPECTED-CHAR`.
- `NL` is suppressed inside `()`, `[]`, and `{}`; each LF/CRLF outside them emits one NL, including blank/comment lines.
- A final `NL` is synthesized before `EOF` when the file does not end with one.
- `#` starts a comment that runs to the end of the line.
- A lowercase name may end in `?` or `!` regardless of whitespace before `(`; `!` followed by `=` stays an operator, so `a!=b` is still `a != b`. The parser rejects suffixes on bindings, parameters, and fields. `try` is a keyword.

## `src/ast.rkt`

Every node is `#:transparent` with `span` as the last field.

| Group | Nodes |
| --- | --- |
| declarations | `program`, `function-decl`, `param`, `struct-decl`, `field-decl`, `type-ref` |
| statements | `binding`, `return-stmt`, `expr-stmt`, `if-branch`, `if-stmt`, `while-stmt`, `for-stmt` |
| expressions | `literal`, `name-ref`, `call`, `named-arg`, `construct`, `list-lit`, `map-lit` (with `map-entry`), `field-access`, `index-access`, `try-expr` (operand, span), `unary`, `binary` |

Design points: one `type-ref` covers `Int`, `List[Int]`, and `List[List[Int]]`; one `literal` covers integers, floats, strings, booleans, and `nil`; grouping `( expr )` produces no node; `call`/`construct` store the name as a string; `unary`/`binary` store the operator as the token-kind symbol (`'plus`, `'and`, `'equal`).

## `src/parser.rkt`

`(parse tokens) -> program | diagnostic`. Recursive descent over the token vector:

- Precedence ladder: or → and → equality → comparison → additive → multiplicative → unary → postfix → primary.
- Arithmetic levels are left-associative; equality and comparison take a single optional operator, so `a < b < c` and `a == b == c` are `PARSE-CHAINED-COMPARISON`, while `a < b == c < d` is valid.
- Top level accepts only `def` and `struct`; anything else is `PARSE-TOP-LEVEL-STATEMENT`.
- A statement starting with `name` is a binding when the next token is `=` or `:`; otherwise it is an expression.
- Stray `NL` tokens are skipped at the top level and between statements (see the gotcha in `SKILL.md`).

## `src/checker.rkt`

`(check program) -> program | diagnostic`. Registration first, then bodies, stopping at the first error:

- Struct names are inserted before fields are resolved, and function signatures after, so forward references, recursion, and struct fields that name a later struct all work.
- Catalogued builtin function names cannot be redefined. `ok` and `error` are additionally reserved on locals, parameters, loop variables, and fields.
- Types are values, not structs: the symbols `Int`, `Float`, `Bool`, `String`, `Nil`, `Json` (opaque, not primitive for equality); `(list 'List T)`; `(list 'Map K V)` with `K` `Int` or `String`; `(list 'Result T)`; `(list 'Struct NAME)`.
- Builtin module calls keep their dotted name in `call-name`. `check-builtin-call` reads arity/signature/fixed types from `builtins.rkt`; generic rules remain explicit stage-local branches. The evaluator reads the same entry's implementation key and trusts checked arity.
- String operations count Unicode characters. Numeric conversions accept signed decimals: non-bang forms return Result; bang failures remain `RUNTIME-INVALID-NUMBER` / `RUNTIME-INTEGER-OVERFLOW`. IO.gets returns Result[String]; IO.gets! retains the old String/EOF diagnostic behavior.
- Expected types must reach builtin calls for contextual ok/error and unwrap/default. An untyped error is CHECK-RESULT-TYPE. `try-expr` requires a Result-returning function and a Result operand; its payload type may differ from the enclosing success type. It does not guarantee a return.
- Scopes are a stack of hashes holding `name -> (cons type immutable?)`. The `for` variable is immutable.
- A plain binding to a visible name is an update and must keep its type; an annotated binding to a visible name is `CHECK-ANNOTATION-ON-EXISTING`; a fresh name that is already visible is `CHECK-SHADOWED-NAME`.
- `check` returns the same `program` when it is valid; the evaluator trusts it and does not re-check types.

## `src/evaluator.rkt`

`(evaluate program #:in #:out #:err #:args #:max-steps) -> 'nil | exit-code | diagnostic`. Runs `main()` and trusts the checker. Ports default to the current ports and the arguments to `'()`; the body runs inside `parameterize` so `IO.*` honors them.

- Values: Racket integers, flonums, booleans, strings, `'nil`, lists, a `mapping` struct (immutable equal?-based hash plus reversed insertion-order keys), an `instance` struct (type name plus an immutable field hash), and `exit-code` for `System.exit`.
- `mapping-put` is the only map writer. Add a key to the reversed key list only on first insertion; replacement keeps its position. `hash-ref` uses a failure thunk for missing keys, never a false/nil sentinel. `Map.size` uses hash-count; Map.keys and debug output follow the stored order. Lookup/update use Racket's effectively constant-time immutable hashes. Run `racket benchmarks/maps.rkt` for three-sample median build/build+read timings outside CI, with checked programs and independent result assertions.
- Results are private tagged `result-ok` and `result-error` structs; false/nil payloads are successes. `try-expr` uses the current function's return escape for errors, so caller restoration remains in call-function. `fallible` converts only documented conversion/EOF failures to Results and preserves bang diagnostic codes.
- Optional max-steps counts expression/statement entries, including repeated loop conditions; each evaluation resets the count. Exhaustion is RUNTIME-STEP-LIMIT; it is not a blocking-I/O timeout.
- `IO.inspect` uses `value->debug-string` (including recursive Result forms), which formats structs in declared field order (the evaluator registers a `struct-fields` hash for this).
- Scopes are a list of frames of `name -> box`. A call starts a fresh scope list (callers' locals are not visible) and one `let/ec` per call for `return`.
- `Int` results of `+ - *` and unary `-` are range-checked to signed 64-bit; `/` and `%` by zero fail for `Int` and `Float`; `==` on numbers uses `=`.
- Index errors point at the index expression; arithmetic errors point at `op-span`.

## `src/json.rkt`

`(read-json-value text) -> json-value`, an opaque wrapper around Racket's JSON data. This helper raises only within the evaluator's local JSON.parse handler, which returns Result[Json]. It delegates grammar parsing to `read-json`, guards raw string controls, checks complete consumption with direct character iteration, and validates finite numbers with `jsexpr?`. Null is represented by `'nil`, false by `#f`, and missing keys are checked by membership, never a payload sentinel. The wrapper is an internal runtime type, not an Agentica constructor.

JSON.encode recursively writes runtime values in evaluator.rkt, preserving struct/map order while `write-json` escapes scalars; failures become RUNTIME-JSON-ENCODE. JSON access/extraction uses Results, including out-of-range Int/Float conversions. IO.inspect prints `<Json>`.

## `src/builtins.rkt`

One catalog of name, parameters, result, generic rule tag, implementation key, effects, and description. `builtin-ref`, `builtin-signature`, and `builtin->jsexpr` serve checker/runtime/help. Shared `type->string` and `did-you-mean` keep help and checking consistent. Effects are informational only. The catalog test exercises each entry with independent expected outputs; do not add test-only exports.

## `src/main.rkt`

Reads the file (a missing file prints one plain line and exits 2), builds a `source`, and calls `lex`, `parse`, `check`, then `evaluate`. A diagnostic is printed by `format-diagnostic` (header, message, source line, caret run) on stderr with exit 1. `--dump` pretty-prints the checked tree instead of running it. Arguments after the source file are passed to the evaluator as `System.args`, and an `exit-code` result exits with that code. No source file exits 2. `check` never runs; --ai/--json use the same structured diagnostic. `help NAME --json` reads the catalog without a source file (unknown target exits 2). Only help handles a trailing --json option, after leading options have been parsed; options on other commands precede the command/file so program args stay intact. --max-steps accepts a positive integer and reaches only evaluation.
