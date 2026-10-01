# Pipeline stages reference

Detailed tables for the Agentica Racket sources. Read this when adding or renaming a token, AST node, or diagnostic code.

## Conventions

- A span end is exclusive; offsets count Racket string characters; line and column are 1-based.
- Every stage is `(stage input) -> data | diagnostic`, stops at the first error, and never prints.
- `format-diagnostic` renders `name:line:column: [CODE] message`.

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
| `def` `struct` `end` `if` `elsif` `else` `while` `for` `in` `return` `true` `false` `nil` `and` `or` `not` | the reserved words |
| `integer` `float` | decimal number literal |
| `string` | decoded string contents |
| `arrow` `equal` `not-equal` `less-equal` `greater-equal` | `->` `==` `!=` `<=` `>=` |
| `left-paren` `right-paren` `left-bracket` `right-bracket` `left-brace` `right-brace` | `(` `)` `[` `]` `{` `}` |
| `comma` `colon` `dot` | `,` `:` `.` |
| `assign` `plus` `minus` `multiply` `divide` `modulo` `less` `greater` | `=` `+` `-` `*` `/` `%` `<` `>` |
| `NL` `EOF` | newline token, end of input |

The parser reads the keyword literals from their kind, not from `value`: `true` → `#t`, `false` → `#f`, `nil` → the symbol `'nil`.

## `src/diagnostic.rkt`

`(struct diagnostic (code message span))`, provided with `format-diagnostic`.

| Stage | Codes |
| --- | --- |
| lexer | `LEX-UNEXPECTED-CHAR`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE` |
| parser | `PARSE-UNEXPECTED-TOKEN`, `PARSE-UNCLOSED-BLOCK`, `PARSE-TOP-LEVEL-STATEMENT`, `PARSE-CHAINED-COMPARISON`, `PARSE-INVALID-ASSIGNMENT-TARGET` |
| checker | `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-REDEFINED-NAME`, `CHECK-ARITY`, `CHECK-TYPE-MISMATCH`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`, `CHECK-MISSING-FIELD`, `CHECK-NOT-A-STRUCT`, `CHECK-NOT-A-LIST`, `CHECK-MAP-KEY-TYPE`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING`, `CHECK-IMMUTABLE-ASSIGNMENT`, `CHECK-MISSING-RETURN`, `CHECK-MAIN`, `CHECK-INT-RANGE`, `CHECK-INTERNAL` |
| evaluator | `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`, `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND`, `RUNTIME-UNREACHABLE` |

## `src/lexer.rkt`

`(lex input) -> (listof token) | diagnostic`. One pass over the source:

- CRLF normalizes to one newline; a lone carriage return is `LEX-UNEXPECTED-CHAR`.
- `NL` is suppressed inside `()` and `[]`; one `NL` per newline sequence outside them.
- A final `NL` is synthesized before `EOF` when the file does not end with one.
- `#` starts a comment that runs to the end of the line.

## `src/ast.rkt`

Every node is `#:transparent` with `span` as the last field.

| Group | Nodes |
| --- | --- |
| declarations | `program`, `function-decl`, `param`, `struct-decl`, `field-decl`, `type-ref` |
| statements | `binding`, `return-stmt`, `expr-stmt`, `if-branch`, `if-stmt`, `while-stmt`, `for-stmt` |
| expressions | `literal`, `name-ref`, `call`, `named-arg`, `construct`, `list-lit`, `map-lit` (with `map-entry`), `field-access`, `index-access`, `unary`, `binary` |

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
- `puts` is pre-registered as `(String) -> Nil` and cannot be redefined.
- Types are values, not structs: the symbols `Int`, `Float`, `Bool`, `String`, `Nil`; `(list 'List T)`; `(list 'Map K V)` with `K` `Int` or `String`; `(list 'Struct NAME)`.
- `Map.has/keys/len/put` and `List.len` are builtin module calls: the parser keeps the dotted name in `call-name`, and `check-builtin-call` types them generically.
- Scopes are a stack of hashes holding `name -> (cons type immutable?)`. The `for` variable is immutable.
- A plain binding to a visible name is an update and must keep its type; an annotated binding to a visible name is `CHECK-ANNOTATION-ON-EXISTING`; a fresh name that is already visible is `CHECK-SHADOWED-NAME`.
- `check` returns the same `program` when it is valid; the evaluator trusts it and does not re-check types.

## `src/evaluator.rkt`

`(evaluate program) -> 'nil | diagnostic`. Runs `main()` and trusts the checker.

- Values: Racket integers, flonums, booleans, strings, `'nil`, lists, a `mapping` struct (association list, insertion order), and an `instance` struct (type name plus an immutable field hash).
- Scopes are a list of frames of `name -> box`. A call starts a fresh scope list (callers' locals are not visible) and one `let/ec` per call for `return`.
- `Int` results of `+ - *` and unary `-` are range-checked to signed 64-bit; `/` and `%` by zero fail for `Int` and `Float`; `==` on numbers uses `=`.
- Index errors point at the index expression; arithmetic errors point at `op-span`.

## `src/main.rkt`

Reads the file (a missing file prints one plain line and exits 2), builds a `source`, and calls `lex`, `parse`, `check`, then `evaluate`. A diagnostic is printed by `format-diagnostic` (header, message, source line, caret run) on stderr with exit 1. `--dump` pretty-prints the checked tree instead of running it. Wrong argument count exits 2.
