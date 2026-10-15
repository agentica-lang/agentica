# Pipeline stages reference

Detailed tables for the Agentica Racket front end. Read this when adding or renaming a token, AST node, or diagnostic code.

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

`token.rkt` also holds `(struct doc-block (text next))`, the `value` of a `DOC` token: `text` is the doc lines with the `##` markers and one optional space removed, joined by newlines; `next` says what the line after the block is: `'blank`, `'comment`, `'eof` or `'code`. The lexer works this out because the `NL` tokens of a blank line and of a `#` comment line look the same.

### Token kinds

| Kind | Lexeme |
| --- | --- |
| `name` | identifier starting with a lowercase letter or `_` |
| `type-name` | identifier starting with an uppercase letter |
| `def` `struct` `enum` `case` `do` `import` `export` `end` `if` `elsif` `else` `while` `for` `in` `return` `try` `true` `false` `nil` `and` `or` `not` | the reserved words |
| `integer` `float` | decimal number literal |
| `string` | decoded string contents |
| `interp-start` `interp-middle` `interp-end` | decoded text before, between and after `#{...}` pieces; the expression tokens come between them |
| `arrow` `equal` `not-equal` `less-equal` `greater-equal` | `->` `==` `!=` `<=` `>=` |
| `left-paren` `right-paren` `left-bracket` `right-bracket` `left-brace` `right-brace` | `(` `)` `[` `]` `{` `}` |
| `comma` `colon` `dot` | `,` `:` `.` |
| `dot-dot` `dot-dot-dot` | `..` `...` (ranges; `1..5` stays two integers, since a Float needs a digit after the dot) |
| `ampersand` | `&` |
| `pipe` `pipe-forward` | `\|` (block parameters) and `\|>` (the pipe operator; longest match, so `do \|x\|` and `\|\|` are unchanged) |
| `and` `or` `not` (symbol forms) | `&&` `\|\|` `!` (a `!` glued to a name stays in the name; `!=` stays `not-equal`) |
| `plus-assign` `minus-assign` `multiply-assign` `divide-assign` `modulo-assign` | `+=` `-=` `*=` `/=` `%=`; the parser desugars `x op= e` into `binding x #f (binary op ...)` |
| `assign` `plus` `minus` `multiply` `divide` `modulo` `less` `greater` | `=` `+` `-` `*` `/` `%` `<` `>` |
| `NL` `EOF` | newline token, end of input |
| `DOC` | one block of `##` doc lines (roadmap 22a); the lexeme is the raw block, the span covers it from the first `##` to the end of the last line, and the `NL` of the line break after it follows as usual |

The parser reads the keyword literals from their kind, not from `value`: `true` → `#t`, `false` → `#f`, `nil` → the symbol `'nil`.

## `src/diagnostic.rkt`

`(diagnostic code message span #:expected #:actual #:callee #:signature #:labels #:help)` constructs a structured diagnostic with optional fields. `format-diagnostic`, `format-diagnostic-ai`, and `diagnostic->jsexpr` present the same data.

| Stage | Codes |
| --- | --- |
| lexer | `LEX-UNEXPECTED-CHAR`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-INVALID-NUMBER`, `LEX-INVALID-UTF8` (raised by `src/source-file.rkt` and `compiler/source_file.agc` when a source file is read, not by the lexer: the span is one character at the first byte of the first sequence that does not decode) |
| parser | `PARSE-PIPE-TARGET`, `PARSE-UNEXPECTED-TOKEN`, `PARSE-UNCLOSED-BLOCK`, `PARSE-TOP-LEVEL-STATEMENT`, `PARSE-CHAINED-COMPARISON`, `PARSE-INVALID-ASSIGNMENT-TARGET`, `PARSE-CONSTANT-NAME`, `PARSE-MISSING-BLANK-LINE`, `PARSE-DETACHED-DOC`, `PARSE-TOO-DEEP` |
| checker | `CHECK-CONSTANT-CYCLE`, `CHECK-CONSTANT-EXPRESSION`, `CHECK-CONSTANT-TYPE`, `CHECK-VOID-TYPE`, `CHECK-VOID-VALUE`, `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-REDEFINED-NAME`, `CHECK-ARITY`, `CHECK-TYPE-MISMATCH`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`, `CHECK-EMPTY-SET-TYPE`, `CHECK-RESULT-TYPE`, `CHECK-EXPECTED-TYPE`, `CHECK-TRY-CONTEXT`, `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`, `CHECK-MISSING-FIELD`, `CHECK-UNKNOWN-METHOD`, `CHECK-PIPE-METHOD`, `CHECK-UNUSED-VALUE`, `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET`, `CHECK-CAPTURED-ASSIGNMENT`, `CHECK-NOT-A-HANDLE`, `CHECK-NOT-A-LIST`, `CHECK-NOT-INDEXABLE`, `CHECK-MAP-KEY-TYPE`, `CHECK-SET-ELEMENT-TYPE`, `CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING`, `CHECK-IMMUTABLE-ASSIGNMENT`, `CHECK-MISSING-RETURN`, `CHECK-MAIN`, `CHECK-INT-RANGE`, `CHECK-INTERNAL`, `CHECK-MODULE-CONTEXT`, `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`, `CHECK-IMPORT-NAME`, `CHECK-IMPORT-RENAME`, `CHECK-DECL-ORDER`, `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`, `CHECK-ENUM-TYPE-INFERENCE`, `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`, `CHECK-UNREACHABLE-CASE-ARM`, `CHECK-LOOP-CONTROL`, `CHECK-TOO-DEEP` |
| runtime (VM) | `RUNTIME-PROCESS-CLOSE`, `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`, `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND`, `RUNTIME-INVALID-NUMBER`, `RUNTIME-INVALID-CHARACTER`, `RUNTIME-INVALID-RANGE`, `RUNTIME-END-OF-INPUT`, `RUNTIME-UNWRAP-ERROR`, `RUNTIME-JSON-ENCODE`, `RUNTIME-STEP-LIMIT`, `RUNTIME-STACK-OVERFLOW`, `RUNTIME-UNREACHABLE`, `RUNTIME-INTERNAL`, `RUNTIME-INVALID-DURATION`, `RUNTIME-TASK-CANCELLED`, `RUNTIME-TASK-AWAIT-CYCLE`, `RUNTIME-TASK-CRASHED`, `RUNTIME-HANDLE-NOT-OWNED`, `RUNTIME-TEST-ASSERTION`, `RUNTIME-TEST-ERROR`, `RUNTIME-TEST-NAME`, `RUNTIME-TEST-PENDING-TASKS`, `RUNTIME-TEST-RUN`, `RUNTIME-TEST-TIMEOUT` |
| lowering (VM) | `LOWER-UNSUPPORTED`, `LOWER-INTERNAL`, `BYTECODE-LIMIT`, `BYTECODE-INTERNAL` (`src/lower.rkt`, `src/bytecode.rkt`; see `docs/vm/03-ir-and-bytecode.md` 3.5) |

Network and protocol failures otherwise return Results; handler and
producer diagnostics retain their original code and span.

## `src/lexer.rkt`

`(lex input) -> (listof token) | diagnostic`. One pass over the source:

- CRLF normalizes to one newline; a lone carriage return is `LEX-UNEXPECTED-CHAR`.
- `NL` is suppressed inside `()`, `[]`, and `{}`; each LF/CRLF outside them emits one NL, including blank/comment lines.
- A final `NL` is synthesized before `EOF` when the file does not end with one.
- `#` starts a comment that runs to the end of the line.
- A line whose first non-blank characters are `##` starts a doc block (`line-start?` looks back over blanks to the line break): `scan-doc-block!` reads the consecutive doc lines into one `DOC` token, with the text after `##` and one optional space (`###` keeps its third `#` in the text). A `##` after code on the line is a plain comment. A bare carriage return after a doc line is still `LEX-UNEXPECTED-CHAR`, found by the main loop. The token is emitted inside brackets too; the parser rejects it there.
- A lowercase name may end in `?` or `!` regardless of whitespace before `(`; `!` followed by `=` stays an operator, so `a!=b` is still `a != b`. The parser rejects suffixes on bindings, parameters, and fields. `try` is a keyword.
- Number literals read digits and `_` in both parts (`1_000.000_5`), drop the `_`s for the value and keep them in the lexeme. `LEX-INVALID-NUMBER` (a trailing `_`, a `__`, or a `_` next to the dot) spans the literal as written. A `.` followed by a digit or `_` continues the number; a letter or another `.` ends it (`1_000.times`, `1_000..2_000`). The text conversions (`String.to_int`, JSON) stay strict and reject `_`.

## `src/ast.rkt`

Every node is `#:transparent` with `span` as the last field, except `program`: `(program declarations span docs module-doc)`. `docs` is an immutable `equal?` hash from the span of each documented node to its doc text, and `module-doc` is the module doc text or `#f`. The key is `node-span` of the node as it stands in its list: the `export-decl` for an exported declaration (not the `def` inside), the `field-decl` in a struct, the `enum-variant` in an enum. The other nodes do not know about docs, so the checker, lowering and bytecode see the tree as before.

| Group | Nodes |
| --- | --- |
| declarations | `program`, `import-decl` (path, `alias` string or `#f`, `names`: a list of `import-name` (name, local, span, local-span), empty for an alias; exactly one of alias and names is set), `export-decl`, `const-decl` (name, `type` or `#f`, value, `exported`, span; `exported` is true for `export NAME = ...`, and the linker clears it), `function-decl`, `param`, `struct-decl`, `enum-decl`, `enum-variant`, `field-decl`, `type-ref` |
| statements | `binding`, `return-stmt`, `loop-control`, `expr-stmt`, `if-branch`, `if-stmt`, `case-stmt`, `case-arm`, `wildcard-pattern`, `literal-pattern`, `variant-pattern`, `while-stmt`, `for-stmt` |
| expressions | `literal`, `type-expression` (name, span; JSON type arguments only), `const-ref` (linked name, span; made by the linker for a read of a constant), `name-ref`, `call`, `enum-constructor`, `function-ref` (name, span), `invoke` (target, args, span), `named-arg`, `construct`, `struct-update` (target, args: `named-arg`s, span, mutable `visible` predicate set by `modules.rkt`; the `value.with(f: x)` copy), `list-lit`, `map-lit` (with `map-entry`), `field-access` (target, name, span, mutable `resolved`), `method-call` (target, name, args, span, mutable `resolved`), `typed-target` (expression, type; checker-made receiver), `interpolation` (parts: strings and expressions, span), `inspection` (target, span; checker-made for `x.inspect`), `block-lit` (params, body, span) with `block-param` (name, type or #f, span), `index-access`, `try-expr` (operand, span), `unary`, `binary` |

Design points: one `type-ref` covers `Int`, `List[Int]`, and `List[List[Int]]`; one `literal` covers integers, floats, strings, booleans, and `nil`; grouping `( expr )` produces no node; `call`/`construct` store the name as a string; `unary`/`binary` store the operator as the token-kind symbol (`'plus`, `'and`, `'equal`).

## `src/parser.rkt`

`(parse tokens) -> program | diagnostic`. Recursive descent over the token vector:

- Precedence ladder: or → and → equality → comparison → pipe → additive → multiplicative → unary → postfix → primary.
- `parse-pipe` (`x |> f(a)`) is left-associative and builds `(call "f" (x a) span #t)`: `call` has a plain `piped` field (the call's span is the right side, the inserted argument keeps the left span); `try` on the right wraps the piped call. The parser records each call it builds from `name(...)`, `Alias.name(...)` or `Result.Ok(...)` in a weak `parenthesized-calls` set (a `do` block rebuild keeps the mark); the right side must be in that set and not already piped, else `PARSE-PIPE-TARGET` at the right side. Every place that rebuilds a `call` (`modules.rkt`, the `do` block in `parse-postfix`) must pass `piped` along.
- Arithmetic levels are left-associative; equality and comparison take a single optional operator, so `a < b < c` and `a == b == c` are `PARSE-CHAINED-COMPARISON`, while `a < b == c < d` is valid.
- Nesting limit (`nesting-limit`, 1000): `nested` counts each statement, expression, prefix operator and type. `link!` counts each operator of a `parse-left-assoc` or `parse-pipe` chain and each suffix in `parse-postfix` as one more level, and what is parsed after the k-th link starts k levels deeper (a loop puts the level back when it ends); beyond the limit is `PARSE-TOO-DEEP` at the current token. `compiler/parse_base.agc` counts the same places (`enter`, `deepen`), so both parsers stop at the same token. The limit bounds the calls of the parser, not the depth of the tree: the right operand of the first link of a chain hangs below the whole chain, so nested chains can build a tree far deeper than 1,000 (measured: 1,990 for two nested chains, about 89,000 for 100). A pass that recurses on the tree needs its own stack or limit.
- Nesting limit of the checker (`nesting-limit`, 1000): `nested` counts each expression (`check-expression`) and each statement (`check-statement`) as one level, so it bounds the depth of the tree; beyond the limit is `CHECK-TOO-DEEP` at the node, with help to split the code. The parser limit does not bound the tree (a nested chain hangs below its first link), and the Agentica checker needs up to 5 VM frames per level (builtins with the nested call as first argument; 3 for `if`, calls and method chains; 6 for each nested block), about 5,000 of the 10,000 at the limit. `compiler/check_state.agc` has the same constant (`nesting_limit`) and counts in `check_expression` and `check_statement`.
- Top level accepts def/struct/enum/import, constants (`NAME = value`, `const-decl`) and export def/struct/enum/constant. `case` uses an optional `do`, `->`, and `end`; `while` and `for` headers also take an optional `do`. A case arm body is either a NL and a block, or one simple statement on the arrow line followed by more statements. A qualified function name without `(` is a `call` with no arguments. `import` has two forms (`parse-import`): `import Alias from "path"` and `import {a, B as C} from "path"`; a string right after `import` (the path-first form of earlier versions) is `PARSE-UNEXPECTED-TOKEN` at the string, with a help that shows the first form; `from` and `as` are plain `name` tokens read by their text, so they stay usable as names. Qualified names cover imported types, enum constructors/patterns, calls and function references. Module nodes must pass through modules.rkt before check.
- `parse-postfix` makes a `struct-update` for `.with(` (the name is exactly `with`, then `(`): named arguments only, at least one, a trailing comma and blocks allowed in the values; `value.with` without `(` stays a field access, and `with` is not a reserved word. `compiler/parser.agc` (`Update(StructUpdate)` in `ast.agc`) and its printer print the same `struct-update` lines.
- A statement starting with `name` is a binding when the next token is `=` or `:`; otherwise it is an expression.
- Stray `NL` tokens are skipped at the top level and between statements (see "Lexer gotcha: stray NL tokens" in `references/frontend.md`).
- Doc blocks (roadmap 22a): `parse-documented` takes an optional `DOC` before a declaration (`parse-declaration`), a field (`parse-field-decl`) or a variant (`parse-variant-decl`). `take-doc!` accepts the block only when `doc-block-next` is `'code` and one `NL` is followed by the member's first token; `record-doc!` then stores the text under the member's span. At the top level, a block with `next` `'blank`, before any declaration and when there is no module doc yet, becomes the module doc. Anything else is `PARSE-DETACHED-DOC` at the block's span (`detached-doc`). Every other place a `DOC` can reach (a function body, inside brackets, before `end`) fails through `bail`, which turns any diagnostic whose token is a `DOC` into `PARSE-DETACHED-DOC`, except `PARSE-MISSING-BLANK-LINE`. The blank-line check in `parse-program` counts a `DOC` as the start of a declaration, so a block right after an `end` gives `PARSE-MISSING-BLANK-LINE` at its first line.

## `src/modules.rkt`

`(load-program path)` links imports before `check`. The std-only guard lives in its name resolution: a two-part name whose module is in `std-only-modules` (`src/builtins.rkt`, today `HttpWire` and `LogRegistry`) and that no import alias names is `CHECK-UNKNOWN-NAME`, with a help that shows the import of its std module (`std-only-imports` in `src/modules.rkt`: `import HTTP from "std/http"` for `HttpWire`, `import Logger from "std/logger"` for `LogRegistry`), unless the module was embedded from `stdlib/` (the `std/` sources of `src/stdlib.rkt`). A user file, a relative import and a `pkg/` module all get it. `HttpWire` is also left out of `help`, its JSON and every "did you mean" (`public-builtin-names`). The linked `program` carries the root file's `docs` and `module-doc`; nothing after the parser reads them.

Names imported with `import {a, B as C} from "path"` live in a per-file table `named-imports` (local name to the module key and the original name), filled by `bind-imported-name!` once the module is loaded, because the checks need its exports. In order, per entry: `CHECK-IMPORT-NAME` at the original name (unknown or private, `unknown-name-help` over the exports), `CHECK-IMPORT-RENAME` at the local name (a type name must start with a capital letter, a function name must not), then `CHECK-REDEFINED-NAME` at the local name against the file's declarations, aliases, other named imports, builtin functions and `reserved-type-names`. `resolve` maps a name without a dot found in the table to the linked name of the export (with the same kind check as `Alias.name`), `rewrite` turns `Color.Red` and `Color.Red(x)` with `Color` an enum in the table into an enum value, and `constructible` (the `visible` predicate of `.with`) also takes the targets of the table. `import-line` renders the line that the `CHECK-IMPORT-PATH` helps show.

## `src/checker.rkt`

`(check program) -> program | diagnostic`. Registration first, then bodies, stopping at the first error:

- Enum names are registered before struct fields resolve; struct names precede field resolution; enum payload templates resolve after all struct names exist; function signatures follow. This allows forward references and generic enum payloads.
- Catalogued builtin function names cannot be redefined. `ok` and `error` are additionally reserved on locals, parameters, loop variables, and fields.
- Types are values, not structs: primitive symbols; builtin type lists such as `(list 'List T)`, `(list 'Map K V)`, `(list 'Set T)`, `(list 'Result T)`, `(list 'Task R)`; `(list 'Struct NAME)`; nominal enum values `(list 'Enum NAME ARG ...)`; and enum-only type variables `(list 'TypeVar NAME)` during payload registration.
- A piped builtin call (`call-piped`) that has a method form for its first parameter's type is `CHECK-PIPE-METHOD` at the call span (`check-pipe-method!`, after the call checks, so type and arity errors come first). The kind comes from the builtin entry's first parameter; the help text is cut from the source with `extent-text`, which starts a piped call or piped `try` at its piped argument and wraps it in parentheses.
- Builtin module calls keep their dotted name in `call-name`. `check-builtin-call` reads arity/signature/fixed types from `builtins.rkt`; generic rules remain explicit stage-local branches. Lowering reads the same entry's implementation key and trusts checked arity.
- String operations count Unicode characters. Numeric conversions accept signed decimals: non-bang forms return Result; bang failures remain `RUNTIME-INVALID-NUMBER` / `RUNTIME-INTEGER-OVERFLOW`. IO.gets returns Result[String]; IO.gets! retains the old String/EOF diagnostic behavior.
- Expected types must reach builtin calls for contextual ok/error and unwrap/default. An untyped error is CHECK-RESULT-TYPE, and a `Channel.new` with no expected type is CHECK-EXPECTED-TYPE. `try-expr` requires a Result-returning function and a Result operand; its payload type may differ from the enclosing success type. It does not guarantee a return. `try` also works in a block whose expected `Fn` has a fixed `Result` type (`Test.test`, `File.each_line`): `check-block-body` knows the block's result from `current-result`. The last expression of such a block is checked as a completion value (`#:completion? (result-type? current-result)`, 7.2.1h), so a Void or non-Result last expression is `CHECK-TYPE-MISMATCH`, not `CHECK-VOID-VALUE`. `conversion-help` gives the help `give a Result with ok() or error("message")` (`ok(...)` when `T` is not Void) for every mismatch whose expected type is a `Result` and whose actual type is not one, a block's last expression or `x: Result[Int] = 5` alike. `try` in a block whose `Result[T]` has an inferred `T` (17a `Task.map`, 15i `File.open` blocks) is not built yet.
- Scopes are a stack of hashes holding `name -> (cons type immutable?)`. The `for` variable is immutable.
- A plain binding to a visible name is an update and must keep its type; an annotated binding to a visible name is `CHECK-ANNOTATION-ON-EXISTING`; a fresh name that is already visible is `CHECK-SHADOWED-NAME`.
- `check` returns the same `program` when it is valid; lowering trusts it and does not re-check types.
- `(check program #:types table)` also records each checked expression node's type in the caller's mutable `eq?` hash (one `hash-set!` in `check-expression`). The literal 2^63 under unary minus is never recorded; `lower.rkt` handles it by rule.

## `src/lower.rkt`

`(lower program types) -> ir-program | diagnostic`. One `ir-function` per `function-decl` in declaration order, then (with module constants) one per kept constant in initialization order, then `<start>` when `ir-program-globals` is above 0, then the block functions; `entry` is `main`, or `<start>` when it exists (`references/vm-lowering.md`). A read of a constant is `global`, or a `const` for a scalar literal. Slots: parameters first, then locals, which are resolved statically and freed when their scope ends, then temporaries with a stack discipline so a call window is always the highest live slots. A new local is lowered straight into its slot; an assignment to an existing local goes through a temporary and `move`. Unsupported forms or types are `LOWER-UNSUPPORTED` at the node span; a Racket exception becomes `LOWER-INTERNAL` at the program span. A `method-call` or `field-access` with `resolved` set lowers its resolved node without a step and checks the outer node's type, because the synthetic call that `check-method` builds is not in the types table; a `typed-target` lowers its expression and checks its recorded type. `format-ir` is the `--dump-ir` text.
Builtin records the VM knows (`builtin-structs`: `FileInfo`, `Header`, `HttpResponse`, `HttpClientOptions`, `ProcessOutput`, fields in record order) are appended to the program's structs when a checked type mentions them, with the records they need (`HttpResponse` needs `Header`); the C side finds them by name (`agc_builtin_struct`).

The Agentica port is `compiler/lowering.agc` and its `lower_*.agc` files (`references/frontend.md`): it must print the same text (`tests/frontend-lower-common.rkt`) for every checked program. A change to `src/lower.rkt` (a bug fix, a builtin name in `vm-builtins`) changes `compiler/lower_tables.agc` (`VM_BUILTINS`) and the port in the same PR, and a golden in `tests/fixtures/frontend/lower/`.

## `src/bytecode.rkt`

`(ir->bytecode ir) -> bc-program | diagnostic` resolves labels, merges adjacent `step`s (split above 65535), and builds the constant pool, builtin imports `(name . arity)` and the span table (span 0 is the program span; multi-span instructions use consecutive entries). `(write-bytecode bc) -> bytes | diagnostic` gives the `.agcb` bytes of `docs/vm/03-ir-and-bytecode.md` 4.6; there is no Racket reader, the C loader is the only one. The Agentica port is `compiler/bytecode_writer.agc` and its `bytecode_*.agc` files (`references/frontend.md`): `tests/frontend-bytecode-test.rkt` checks that both write the same bytes, so a change to `src/bytecode.rkt` (a bug fix, an opcode, a section) changes `compiler/` in the same PR, with the opcode table of `bytecode_tables.agc` (`OPCODES`) and the version (`VERSION`, `src/version.rkt`) kept equal. `bc-program` also holds the interned `updates` (struct index and updated field indexes, one `STRUCT_WITH` operand each). The file is format version 5: after the Updates section the writer writes the Globals count (`u32`, always 0 until module constants are lowered, 44a2), and `opcodes` ends with `global` and `global-set`, which nothing emits yet. `BYTECODE-LIMIT` when a function needs more than 65535 registers or the program has more than 65535 struct updates; both functions turn a Racket exception into `BYTECODE-INTERNAL` at the program span.

## `src/builtins.rkt`

One catalog of name, parameters, result, generic rule tag, implementation key, effects, and description. `std-only-modules` (`HttpWire`, `LogRegistry`) lists modules only `stdlib/` may call (`std-only-name?`; `public-builtin-names` leaves them out for help and suggestions). `builtin-ref`, `builtin-signature`, and `builtin->jsexpr` serve checker/lowering/help. Shared `type->string` and `did-you-mean` keep help and checking consistent. Effects are informational only, except that a builtin with no effects whose result is unused is `CHECK-UNUSED-VALUE`: the `Test` assertions carry the effect `test` so they may stand as statements. `Test.eq` uses the rule `test-eq`: both arguments have one type that passes `data-type?` (the types with `to_s`, which are the §25.4 equality set plus `Json`); `TestCase` is in `opaque-types` and `Test` is a reserved name. Every entry's implementation key must be in `vm-builtins` (`tests/bytecode-test.rkt`) and run in a golden fixture; do not add test-only exports.

`builtin` has an automatic alternatives field, filled only during catalog initialization. `builtin-ref` optionally selects a signature by arity; checker and lowering use the same selection. Map.get/2 returns Result[V]; Map.get/3 returns V with an eagerly evaluated default. Text help lists both signatures, and its JSON help carries overloads; single-signature JSON output is unchanged. List.repeat count errors are RUNTIME-INVALID-COUNT at the argument span, with a 1048576-element cap. List.set reuses RUNTIME-INDEX-OUT-OF-RANGE. Map.delete removes both hash storage and insertion-order keys.

## `src/main.rkt`

`test` parses its own options (paths, at most one --steps, at most one --only TEXT, --allow-run, --seed, --ai/--json; no paths means the defaults, chosen by the driver) and calls `run-agentica-test` in `src/bdd-driver.rkt`, then prints the text it returns and exits with its code. BDD options after test are parsed separately so ordinary program arguments remain untouched.

Reads the file (a missing file prints one plain line and exits 2), builds a `source`, and calls `lex`, `parse`, `link-program`, `check` and `lower`, then runs the bytecode on the VM. A diagnostic is printed by `format-diagnostic` (header, message, source line, caret run) on stderr with exit 1. `--dump` pretty-prints the checked tree instead of running it; `--dump-ir` prints `format-ir` of the lowered program. `compile FILE -o OUT` (first argument only, exactly that shape, else usage exit 2) checks, lowers and writes bytecode, and it cannot be combined with `--dump` or `--dump-ir` (usage, exit 2); the `#:types` table is built only for `compile` and `--dump-ir`; lowering diagnostics exit 1, an unwritable output prints one line and exits 2. Arguments after the source file reach the VM as `System.args`, and the driver exits with the VM's code. No source file exits 2. `check` never runs; --ai/--json use the same structured diagnostic. `help NAME --json` reads the catalog without a source file (unknown target exits 2); `help` alone (exit 0) prints the command summary and the builtin namespaces derived from `public-builtin-names`. The summary strings are the `#:usage-help` lines of `command-line` (through the `command-line/summary` macro, since `command-line` needs literal strings), so `--help` and `help` share one text. Help and test handle trailing style options; options on other commands precede the command/file so program args stay intact. --max-steps accepts a positive integer and reaches only the VM. --allow-run enables Process.spawn and, for `test`, reaches step handlers and programs under test; check and help need no flag.
