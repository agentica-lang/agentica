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
| `def` `struct` `enum` `case` `do` `import` `export` `end` `if` `elsif` `else` `while` `for` `in` `return` `try` `true` `false` `nil` `and` `or` `not` | the reserved words |
| `integer` `float` | decimal number literal |
| `string` | decoded string contents |
| `interp-start` `interp-middle` `interp-end` | decoded text before, between and after `#{...}` pieces; the expression tokens come between them |
| `arrow` `equal` `not-equal` `less-equal` `greater-equal` | `->` `==` `!=` `<=` `>=` |
| `left-paren` `right-paren` `left-bracket` `right-bracket` `left-brace` `right-brace` | `(` `)` `[` `]` `{` `}` |
| `comma` `colon` `dot` | `,` `:` `.` |
| `dot-dot` `dot-dot-dot` | `..` `...` (ranges; `1..5` stays two integers, since a Float needs a digit after the dot) |
| `ampersand` | `&` |
| `and` `or` `not` (symbol forms) | `&&` `\|\|` `!` (a `!` glued to a name stays in the name; `!=` stays `not-equal`) |
| `plus-assign` `minus-assign` `multiply-assign` `divide-assign` `modulo-assign` | `+=` `-=` `*=` `/=` `%=`; the parser desugars `x op= e` into `binding x #f (binary op ...)` |
| `assign` `plus` `minus` `multiply` `divide` `modulo` `less` `greater` | `=` `+` `-` `*` `/` `%` `<` `>` |
| `NL` `EOF` | newline token, end of input |

The parser reads the keyword literals from their kind, not from `value`: `true` → `#t`, `false` → `#f`, `nil` → the symbol `'nil`.

## `src/diagnostic.rkt`

`(diagnostic code message span #:expected #:actual #:callee #:signature #:labels #:help)` constructs a structured diagnostic with optional fields. `format-diagnostic`, `format-diagnostic-ai`, and `diagnostic->jsexpr` present the same data.

| Stage | Codes |
| --- | --- |
| lexer | `LEX-UNEXPECTED-CHAR`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE` |
| parser | `PARSE-UNEXPECTED-TOKEN`, `PARSE-UNCLOSED-BLOCK`, `PARSE-TOP-LEVEL-STATEMENT`, `PARSE-CHAINED-COMPARISON`, `PARSE-INVALID-ASSIGNMENT-TARGET`, `PARSE-MISSING-BLANK-LINE` |
| checker | `CHECK-VOID-TYPE`, `CHECK-VOID-VALUE`, `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-REDEFINED-NAME`, `CHECK-ARITY`, `CHECK-TYPE-MISMATCH`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`, `CHECK-RESULT-TYPE`, `CHECK-TRY-CONTEXT`, `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`, `CHECK-MISSING-FIELD`, `CHECK-UNKNOWN-METHOD`, `CHECK-UNUSED-VALUE`, `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET`, `CHECK-CAPTURED-ASSIGNMENT`, `CHECK-NOT-A-LIST`, `CHECK-NOT-INDEXABLE`, `CHECK-MAP-KEY-TYPE`, `CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING`, `CHECK-IMMUTABLE-ASSIGNMENT`, `CHECK-MISSING-RETURN`, `CHECK-MAIN`, `CHECK-INT-RANGE`, `CHECK-INTERNAL`, `CHECK-MODULE-CONTEXT`, `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`, `CHECK-IMPORT-NAME`, `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`, `CHECK-ENUM-TYPE-INFERENCE`, `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`, `CHECK-UNREACHABLE-CASE-ARM`, `CHECK-LOOP-CONTROL` |
| evaluator | `RUNTIME-PROCESS-CONTEXT`, `RUNTIME-PROCESS-CLOSE`, `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`, `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND`, `RUNTIME-INVALID-NUMBER`, `RUNTIME-INVALID-CHARACTER`, `RUNTIME-INVALID-RANGE`, `RUNTIME-END-OF-INPUT`, `RUNTIME-UNWRAP-ERROR`, `RUNTIME-JSON-ENCODE`, `RUNTIME-STEP-LIMIT`, `RUNTIME-STACK-OVERFLOW`, `RUNTIME-UNREACHABLE`, `RUNTIME-INTERNAL`, `RUNTIME-INVALID-DURATION`, `RUNTIME-TASK-CONTEXT`, `RUNTIME-TASK-CANCELLED` (also when awaiting work cancelled by network resource shutdown) |
| lowering (VM) | `LOWER-UNSUPPORTED`, `LOWER-INTERNAL`, `BYTECODE-LIMIT`, `BYTECODE-INTERNAL` (`src/lower.rkt`, `src/bytecode.rkt`; see `docs/vm/03-ir-and-bytecode.md` 3.5) |

Network and protocol failures otherwise return Results; handler and
producer diagnostics retain their original code and span.

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
| declarations | `program`, `import-decl`, `export-decl`, `function-decl`, `param`, `struct-decl`, `enum-decl`, `enum-variant`, `field-decl`, `type-ref` |
| statements | `binding`, `return-stmt`, `loop-control`, `expr-stmt`, `if-branch`, `if-stmt`, `case-stmt`, `case-arm`, `wildcard-pattern`, `literal-pattern`, `variant-pattern`, `while-stmt`, `for-stmt` |
| expressions | `literal`, `type-expression` (name, span; JSON type arguments only), `name-ref`, `call`, `enum-constructor`, `function-ref` (name, span), `invoke` (target, args, span), `named-arg`, `construct`, `list-lit`, `map-lit` (with `map-entry`), `field-access` (target, name, span, mutable `resolved`), `method-call` (target, name, args, span, mutable `resolved`), `typed-target` (expression, type; checker-made receiver), `interpolation` (parts: strings and expressions, span), `inspection` (target, span; checker-made for `x.inspect`), `block-lit` (params, body, span) with `block-param` (name, type or #f, span), `index-access`, `try-expr` (operand, span), `unary`, `binary` |

Design points: one `type-ref` covers `Int`, `List[Int]`, and `List[List[Int]]`; one `literal` covers integers, floats, strings, booleans, and `nil`; grouping `( expr )` produces no node; `call`/`construct` store the name as a string; `unary`/`binary` store the operator as the token-kind symbol (`'plus`, `'and`, `'equal`).

## `src/parser.rkt`

`(parse tokens) -> program | diagnostic`. Recursive descent over the token vector:

- Precedence ladder: or → and → equality → comparison → additive → multiplicative → unary → postfix → primary.
- Arithmetic levels are left-associative; equality and comparison take a single optional operator, so `a < b < c` and `a == b == c` are `PARSE-CHAINED-COMPARISON`, while `a < b == c < d` is valid.
- Top level accepts def/struct/enum/import and export def/struct/enum. `case` uses an optional `do`, `->`, and `end`; `while` and `for` headers also take an optional `do`. A case arm body is either a NL and a block, or one simple statement on the arrow line followed by more statements. A qualified function name without `(` is a `call` with no arguments. as is contextual. Qualified names cover imported types, enum constructors/patterns, calls and function references. Module nodes must pass through modules.rkt before check.
- A statement starting with `name` is a binding when the next token is `=` or `:`; otherwise it is an expression.
- Stray `NL` tokens are skipped at the top level and between statements (see the gotcha in `SKILL.md`).

## `src/modules.rkt`

`(load-program path)` links imports before `check`. The std-only guard lives in its name resolution: a two-part name whose module is in `std-only-modules` (`src/builtins.rkt`, today `HttpWire`) and that no import alias names is `CHECK-UNKNOWN-NAME`, with a help that shows `import "std/http" as Web`, unless the module was embedded from `stdlib/` (the `std/` sources of `src/stdlib.rkt`). A user file, a relative import and a `pkg/` module all get it. `HttpWire` is also left out of `help`, its JSON and every "did you mean" (`public-builtin-names`).

## `src/checker.rkt`

`(check program) -> program | diagnostic`. Registration first, then bodies, stopping at the first error:

- Enum names are registered before struct fields resolve; struct names precede field resolution; enum payload templates resolve after all struct names exist; function signatures follow. This allows forward references and generic enum payloads.
- Catalogued builtin function names cannot be redefined. `ok` and `error` are additionally reserved on locals, parameters, loop variables, and fields.
- Types are values, not structs: primitive symbols; builtin type lists such as `(list 'List T)`, `(list 'Map K V)`, `(list 'Result T)`, `(list 'Task R)`; `(list 'Struct NAME)`; nominal enum values `(list 'Enum NAME ARG ...)`; and enum-only type variables `(list 'TypeVar NAME)` during payload registration.
- Builtin module calls keep their dotted name in `call-name`. `check-builtin-call` reads arity/signature/fixed types from `builtins.rkt`; generic rules remain explicit stage-local branches. The evaluator reads the same entry's implementation key and trusts checked arity.
- String operations count Unicode characters. Numeric conversions accept signed decimals: non-bang forms return Result; bang failures remain `RUNTIME-INVALID-NUMBER` / `RUNTIME-INTEGER-OVERFLOW`. IO.gets returns Result[String]; IO.gets! retains the old String/EOF diagnostic behavior.
- Expected types must reach builtin calls for contextual ok/error and unwrap/default. An untyped error is CHECK-RESULT-TYPE. `try-expr` requires a Result-returning function and a Result operand; its payload type may differ from the enclosing success type. It does not guarantee a return.
- Scopes are a stack of hashes holding `name -> (cons type immutable?)`. The `for` variable is immutable.
- A plain binding to a visible name is an update and must keep its type; an annotated binding to a visible name is `CHECK-ANNOTATION-ON-EXISTING`; a fresh name that is already visible is `CHECK-SHADOWED-NAME`.
- `check` returns the same `program` when it is valid; the evaluator trusts it and does not re-check types.
- `(check program #:types table)` also records each checked expression node's type in the caller's mutable `eq?` hash (one `hash-set!` in `check-expression`). The literal 2^63 under unary minus is never recorded; `lower.rkt` handles it by rule.

## `src/lower.rkt`

`(lower program types) -> ir-program | diagnostic`. One `ir-function` per `function-decl` (index order = declaration order, `entry` = `main`). Slots: parameters first, then locals, which are resolved statically like the evaluator's `define!`/`assign!` and freed when their scope ends, then temporaries with a stack discipline so a call window is always the highest live slots. A new local is lowered straight into its slot; an assignment to an existing local goes through a temporary and `move`. Unsupported forms or types are `LOWER-UNSUPPORTED` at the node span; a Racket exception becomes `LOWER-INTERNAL` at the program span. A `method-call` or `field-access` with `resolved` set lowers its resolved node without a step and checks the outer node's type, because the synthetic call that `check-method` builds is not in the types table; a `typed-target` lowers its expression and checks its recorded type. `format-ir` is the `--dump-ir` text.
Builtin records the VM knows (`builtin-structs`: `FileInfo`, `Header`, `HttpResponse`, `HttpClientOptions`, `ProcessOutput`, fields in record order) are appended to the program's structs when a checked type mentions them, with the records they need (`HttpResponse` needs `Header`); the C side finds them by name (`agc_builtin_struct`). `(check-vm-only program reason)` walks a checked program and returns a `LOWER-UNSUPPORTED` diagnostic ("this program needs the VM: ... but <reason>") at the first call in `vm-only-builtins`, or `#f`; `src/main.rkt` (the fallback and `--legacy-eval`) and `read-program` in `src/bdd-runner.rkt` call it before the evaluator gets a program, and only print it.

## `src/bytecode.rkt`

`(ir->bytecode ir) -> bc-program | diagnostic` resolves labels, merges adjacent `step`s (split above 65535), and builds the constant pool, builtin imports `(name . arity)` and the span table (span 0 is the program span; multi-span instructions use consecutive entries). `(write-bytecode bc) -> bytes | diagnostic` gives the `.agcb` bytes of `docs/vm/03-ir-and-bytecode.md` 4.6; there is no Racket reader, the C loader is the only one. `BYTECODE-LIMIT` when a function needs more than 65535 registers; both functions turn a Racket exception into `BYTECODE-INTERNAL` at the program span.

## `src/evaluator.rkt`

`(evaluate program #:in #:out #:err #:args #:max-steps #:entrypoint #:arguments #:builtin-handler #:require-complete-tasks? #:allow-run) -> value | exit-code | diagnostic`. Runs main by default and trusts the checker. BDD uses checked callback entrypoints, contextual services and the require-complete-tasks? policy. Each invocation supervises task-local workers with shared immutable tables and one global step budget. Ports and arguments retain their defaults.

- Values: Racket integers, flonums, booleans, strings, `'nil`, lists, an `enum-value` tagged with canonical enum/variant names and a payload list, a `mapping` struct (immutable equal?-based hash plus reversed insertion-order keys), an `instance` struct (type name plus an immutable field hash), and `exit-code` for `System.exit`.
- `mapping-put` is the only map writer. Add a key to the reversed key list only on first insertion; replacement keeps its position. `hash-ref` uses a failure thunk for missing keys, never a false/nil sentinel. `Map.size` uses hash-count; Map.keys and debug output follow the stored order. Lookup/update use Racket's effectively constant-time immutable hashes. Run `racket benchmarks/maps.rkt` for three-sample median build/build+read timings outside CI, with checked programs and independent result assertions.
- Results are private tagged `result-ok` and `result-error` structs; false/nil payloads are successes. `try-expr` uses the current function's return escape for errors, so caller restoration remains in call-function. `fallible` converts only documented conversion/EOF failures to Results and preserves bang diagnostic codes.
- Function values use a `function-value` name handle, invoked through the same call-function path as direct calls. Checker types are `(list 'Fn PARAM ... RETURN)`; Fn and BDD names are reserved. No closures, equality or JSON encoding.
- `IO.read_bytes(count)` returns Result[List[Int]] using native read-bytes, waiting for count bytes or EOF; short/empty EOF succeeds. Validate 0..1048576 before allocation/consumption; zero reads nothing. Input-port failures are recoverable. `String.from_bytes` validates 0..255 then strictly decodes UTF-8 with bytes->string/utf-8 and no replacement character.
- `IO.flush` flushes current-output-port only, returning Void completion. EOF uses peek-byte rather than peek-char, so partial UTF-8 input is data, not a reason to wait for a whole character. EOF peeking can still block and is not a readiness poll. Text/byte readers share the same buffered port; IO.read still drains until EOF. Reads have no timeout.
- Optional max-steps counts expression/statement entries, including repeated loop conditions; each evaluation resets the count. Exhaustion is RUNTIME-STEP-LIMIT; it is not a blocking-I/O timeout.
- `IO.inspect` uses `value->debug-string` (including recursive Result forms), which formats structs in declared field order (the evaluator registers a `struct-fields` hash for this) and enum values as `Enum.Variant(payload)`. `value->text` is the `to_s` form used by `puts`, `print` and interpolation.
- Scopes are a list of frames of `name -> box`. A call starts a fresh scope list (callers' locals are not visible) and one `let/ec` per call for `return`.
- `Int` results of `+ - *` and unary `-` are range-checked to signed 64-bit; `/` and `%` by zero fail for `Int` and `Float`; `==` on numbers uses `=`.
- Index errors point at the index expression; arithmetic errors point at `op-span`.

## `src/json.rkt`

`(read-json-value text) -> json-value`, an opaque wrapper around Racket's JSON data. This helper raises only within the evaluator's local JSON.parse handler, which returns Result[Json]. It delegates grammar parsing to `read-json`, guards raw string controls, checks complete consumption with direct character iteration, and validates finite numbers with `jsexpr?`. Null is represented by `'nil`, false by `#f`, and missing keys are checked by membership, never a payload sentinel. The wrapper is an internal runtime type, not an Agentica constructor.

JSON.encode recursively writes runtime values in evaluator.rkt, preserving struct/map order while `write-json` escapes scalars; failures become RUNTIME-JSON-ENCODE. JSON access/extraction uses Results, including out-of-range Int/Float conversions. IO.inspect prints `<Json>`.

## `src/builtins.rkt`

One catalog of name, parameters, result, generic rule tag, implementation key, effects, and description. `std-only-modules` (`HttpWire`) lists modules only `stdlib/` may call (`std-only-name?`; `public-builtin-names` leaves them out for help and suggestions), and `vm-only-builtins` the builtins the evaluator cannot run (every `HttpWire` builtin, `Process.spawn_captured` and `Process.output`; the evaluator has no implementation for them). `builtin-ref`, `builtin-signature`, and `builtin->jsexpr` serve checker/runtime/help. Shared `type->string` and `did-you-mean` keep help and checking consistent. Effects are informational only. The catalog test exercises each entry with independent expected outputs; do not add test-only exports.

`builtin` has an automatic alternatives field, filled only during catalog initialization. `builtin-ref` optionally selects a signature by arity; checker and evaluator use the same selection. Map.get/2 returns Result[V]; Map.get/3 returns V with an eagerly evaluated default. Text help lists both signatures, and its JSON help carries overloads; single-signature JSON output is unchanged. List.repeat count errors are RUNTIME-INVALID-COUNT at the argument span, with a 1048576-element cap. List.set reuses RUNTIME-INDEX-OUT-OF-RANGE. Map.delete removes both hash storage and insertion-order keys.

## `src/filesystem.rkt`

`filesystem-call` implements the File, Dir and Path catalog entries. Opaque FileHandle and FileInfo record layout live in builtin-types.rkt. The evaluator supplies the execution owner and shutdown hook; file ports are created under child custodians of that execution and close on explicit close, active-I/O timeout or run cleanup. task-run's cleanup hook flushes registered output handles before shutting down the run custodian. The per-handle lock covers full timed operations. Whole-file helpers enforce the UTF-8 byte cap before returning data; filesystem errors are Results.

## `src/process.rkt`

Opaque evaluation-owned children with a pending-spawn registry, independent stream locks, direct argv, stderr forwarding and kill/reap cleanup. process-call dispatch returns values, Results, or located context/close diagnostics. --allow-run gates spawning only. Completion uses Racket void. task-run's watcher invokes cleanup once before shutdown for both normal return and supervisor death.

## `src/main.rkt`

`test` dispatches to bdd-runner before the normal language pipeline. It accepts feature paths, repeatable --steps and --allow-run, discovers sorted features, prints plain/AI/JSON reports and enforces report exit_code. Ordinary evaluation installs the BDD.run service. BDD options after test are parsed separately so ordinary program arguments remain untouched.

Reads the file (a missing file prints one plain line and exits 2), builds a `source`, and calls `lex`, `parse`, `check`, then `evaluate`. A diagnostic is printed by `format-diagnostic` (header, message, source line, caret run) on stderr with exit 1. `--dump` pretty-prints the checked tree instead of running it; `--dump-ir` prints `format-ir` of the lowered program. `compile FILE -o OUT` (first argument only, exactly that shape, else usage exit 2) checks, lowers and writes bytecode, and it cannot be combined with `--dump` or `--dump-ir` (usage, exit 2); the `#:types` table is built only for `compile` and `--dump-ir`; lowering diagnostics exit 1, an unwritable output prints one line and exits 2. Arguments after the source file are passed to the evaluator as `System.args`, and an `exit-code` result exits with that code. No source file exits 2. `check` never runs; --ai/--json use the same structured diagnostic. `help NAME --json` reads the catalog without a source file (unknown target exits 2). Help and test handle trailing style options; options on other commands precede the command/file so program args stay intact. --max-steps accepts a positive integer and reaches only evaluation. --allow-run enables Process.spawn and is propagated to BDD handlers and programs under test; check and help need no flag.

## Gherkin and BDD modules

BDD is moving from Racket to Agentica (phase 21, `docs/future/31-bdd-in-agentica.md`). Until 21f switches `agentica test` over, the Racket pieces below run it, and the Agentica pieces (the last items) live in `stdlib/bdd/`, registered in `src/stdlib.rkt`. They are internal: importable through `std/` like any registered module, but unsupported, not in the programming skill or the site, with no import guard. Each is tested by golden fixtures that import it directly.

- `parse-gherkin(source)` returns a feature with expanded scenarios or one diagnostic. Nodes retain spans; scenario Examples rows have separate locations. Parser codes use `PARSE-GHERKIN-HEADER`, `STEP`, `ARGUMENT`, `TABLE`, `EXAMPLES`, `TAGS`, `EMPTY`, `PARAMETER`, and `UNSUPPORTED` with the same prefix.
- `run-bdd(paths #:steps #:command)` returns a JSON-compatible report, accumulating independent file/scenario results. The optional command is a local executable/argument list; by default it uses the current compiled CLI or Racket and src/main.rkt. `make-bdd-service` supplies the evaluator's BDD.run bridge. Resolution errors use `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, and `CHECK-BDD-EMPTY`.
- `bdd-call` executes contextual operations and returns a value, `bdd-result` or diagnostic. `bdd-limit` supervises operations under a scenario custodian/deadline; `bdd-cleanup!` removes its container and shuts down ports/workers. Runtime codes use `RUNTIME-BDD-CONTEXT`, `ASSERTION`, `NO-ASSERTION`, `PREMATURE-EXIT`, `DUPLICATE`, `PATTERN`, `TIMEOUT`, `OUTPUT-LIMIT`, `PROGRAM`, `JSON`, `IO`, `INFRA`, and `USAGE` with the same prefix; `src/task.rkt` raises `RUNTIME-BDD-PENDING-TASKS` when a handler leaves tasks running. These are independent of errors emitted by candidate programs on their captured stderr.
- `stdlib/bdd/gherkin.agc` (`std/bdd/gherkin`, 21c) mirrors `src/gherkin.rkt`: the same subset, codes, first error and spans. `parse(file, text)` returns `Outcome.Done(Feature)` or `Outcome.Failed(Diagnostic)` (code, message, `Span`); a `Span` is file, line, column 1 and the end column of the raw line, with no offset. A step's `argument` is `NoArgument`, `DocString` or `DataTable`; a scenario's `example` is `NoExample` or the Examples `Row` span; kinds are the strings `Given`, `When` and `Then`. Goldens: `bdd-gherkin-outline`, `-sections` and `-arguments` (every case of `tests/gherkin-test.rkt`, which 21f deletes with `src/gherkin.rkt`). Keep the two parsers in step until then.
