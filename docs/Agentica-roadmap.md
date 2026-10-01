# Agentica implementation roadmap

This roadmap turns the core specification in [`Agentica-gramatica.md`](Agentica-gramatica.md) into a usable interpreter. Keep every phase focused on the core in sections 4–6 until the prototype can run and diagnose the examples in sections 9–10. Enums and other extensions stay out of the initial milestone.

## Phase 1: Source handling and lexer

Build only the first working slice: `.agc` text in, located tokens (or a located lexical diagnostic) out. Keep `src/` flat and create modules when this phase needs them; do not add empty parser, checker, evaluator, or pipeline placeholders.

### `src/` organization for this phase

```text
src/
├── main.rkt       # existing CLI entry point; read a file and show lexer output/errors
├── source.rkt     # source text and source positions/spans
├── diagnostic.rkt # shared lexical diagnostic representation/formatting
├── token.rkt      # token kinds and token data
└── lexer.rkt      # source text -> tokens or lexical diagnostics

tests/
└── lexer-test.rkt # focused lexer behavior tests
```

Keep source positions and token/diagnostic data separate from lexing rules. `main.rkt` remains a thin driver; no general pipeline module is needed until multiple stages are connected. Use Racket's built-in test support; add no dependencies.

### Work sequence

1. Add the minimal source representation: file name, source text, and spans with offsets plus 1-based line/column positions. Define whether span ends are exclusive and use that convention consistently.
2. Define token kinds and token data, including a span. Cover the core grammar's identifiers, reserved words, literals, punctuation, operators, `NL`, and `EOF` only.
3. Implement the lexer as a single pass. Normalize CRLF as one newline, track positions, ignore spaces/tabs, preserve newline tokens inside comments, and suppress newline tokens while inside `()` or `[]`. Emit one `NL` for each newline sequence outside delimiters and synthesize a final `NL` before `EOF` when needed.
4. Recognize ASCII identifiers and the specified reserved words; decimal integers/floats; strings with only the documented escapes; delimiters and operators. Reject unsupported characters, malformed escapes, unterminated strings, and mismatched/unclosed delimiters with stable error codes and source spans.
5. Connect `main.rkt` to read UTF-8 `.agc` files, invoke the lexer, and print tokens or a concise diagnostic. Keep presentation at the CLI boundary; the lexer returns data, not printed errors.
6. Add focused tests for token kinds and spans, CRLF/final-newline behavior, comments and multiline delimiters, every supported escape/operator, and representative malformed input. Run them with `raco test tests/lexer-test.rkt` and smoke-test `racket src/main.rkt examples/hello.agc`.

### Phase 1 checklist

- [x] Read UTF-8 `.agc` source files and preserve file, line, and column positions.
- [x] Normalize CRLF, emit one `NL` per newline sequence outside delimiters, and add a final `NL` when needed.
- [x] Tokenize identifiers, reserved words, integer and float literals, strings and escapes, comments, delimiters, and operators.
- [x] Report lexical errors with source locations and stable error codes.
- [x] Expose lexer output through the existing CLI and cover core behavior with focused tests.

**Complete when:** the sample file produces inspectable tokens, and malformed characters, strings, or delimiters produce Agentica diagnostics with useful locations—not Racket tracebacks.

## Phase 2: AST and parser

Turn the located tokens from Phase 1 into a syntax tree, or a located syntax diagnostic. Keep the same shape: `parse` takes the token list `lex` returned and gives back a program or one diagnostic, and stops at the first error. No checker, evaluator, or pipeline module yet.

### `src/` organization for this phase

```text
src/
├── main.rkt       # CLI: lex, parse, show the tree or the first diagnostic
├── source.rkt     # unchanged
├── diagnostic.rkt # unchanged
├── token.rkt      # unchanged
├── lexer.rkt      # unchanged
├── ast.rkt        # syntax tree nodes; every node carries a span
└── parser.rkt     # token list -> program or syntax diagnostic

tests/
├── lexer-test.rkt  # unchanged
└── parser-test.rkt # focused parser behavior tests
```

Keep the AST free of parsing rules and the parser free of checking rules. Do not add checker/evaluator files, and do not add placeholder nodes for enums, generics, or modules.

### AST design

- One `type-ref` node covers `Int`, `List[Int]`, and `List[List[Int]]`: a type name plus a list of type arguments. No separate primitive/application nodes.
- One `literal` node covers integers, floats, strings, `true`/`false`, and `nil`; the checker dispatches on the Racket value. The parser maps the keyword kinds to `#t`, `#f`, and the symbol `'nil` (the lexer stores the lexeme string as the token value, not the decoded literal).
- Grouping `( expr )` produces no node; the inner expression is returned unchanged.
- Every node has a `span`. A composite node's span runs from its first consumed token to its last.
- Nodes: `program`; `function-decl`, `param`, `struct-decl`, `field-decl`, `type-ref`; `binding`, `return-stmt`, `expr-stmt`, `if-stmt`/`if-branch`, `while-stmt`, `for-stmt`; `literal`, `name-ref`, `call`, `named-arg`, `construct`, `list-lit`, `field-access`, `index-access`, `unary`, `binary`.
- `call` and `construct` store the callee/type name as a string, not a `name-ref` node; the node's span starts at that name. `unary`/`binary` store the operator as the token-kind symbol (`'plus`, `'and`, `'equal`, …).

### Work sequence

1. Add `src/ast.rkt`: the nodes above, each a `#:transparent` struct with a `span`, and `(provide (struct-out …))` for each.
2. Add `src/parser.rkt` with a cursor over the token list: `peek`/`current`/`advance!`/`expect`/`skip-newlines!`, and a `fail` that builds a `diagnostic` from a token's span. It returns data, never prints.
3. Parse types and declarations: `program`, `function-decl`, `struct-decl`, `param`, `field-decl`.
4. Parse statements and blocks: `binding`, `return-stmt`, `expr-stmt`, `if`/`elsif`/`else`, `while`, `for`. Blocks end at `end`, `elsif`, or `else`, and use `end` rather than indentation.
5. Parse expressions with the section 5 precedence ladder (or → and → equality → comparison → additive → multiplicative → unary → postfix → primary) and left associativity for the arithmetic levels. Equality and comparison take a single optional operator, so they do not chain.
6. Wire `main.rkt`: lex, then parse; print the syntax diagnostic on stderr and exit 1, otherwise print the tree. Make `source` opaque (drop `#:transparent`) so `pretty-print` shows `#<source>` instead of repeating the whole file text inside every span.
7. Add `tests/parser-test.rkt`; change CI to `raco test tests/` (runs both files) and keep the `racket src/main.rkt examples/hello.agc` smoke test.

### Parser rules and edge cases

- Executable statements at top level (`puts("hello")`, `age: Int = "25"`) are `PARSE-TOP-LEVEL-STATEMENT`; the top level accepts only `def` and `struct` declarations.
- Comparison and equality do not chain: `a < b < c` and `a == b == c` are `PARSE-CHAINED-COMPARISON`. `a < b == c < d` is valid, because the grammar allows one comparison on each side of `==`.
- A statement that starts with `NAME` is a binding when the next token is `=` or `:`, and an expression otherwise. `x[0] = 1` and `x.y = 1` are `PARSE-INVALID-ASSIGNMENT-TARGET`; the core has no field or index assignment.
- A bare `TYPE_NAME` in expression position is an error: a type name is only a type or a constructor call.
- `if 1` and other semantic errors are syntactically valid here; Phase 3 rejects them.
- Trailing commas are accepted in parameters, arguments, named arguments, and list literals, as the grammar allows.
- NL handling: skip stray `NL` tokens between declarations, between statements, and before `EOF`. The lexer collapses a run of blank lines into one `NL`, but emits separate `NL` tokens around comment lines, so a blank line or comment between two statements can leave more than one.
- Stop at the first error and return one diagnostic, as the lexer does. No error recovery in this phase.
- Diagnostic codes: `PARSE-UNEXPECTED-TOKEN` (expected X, found Y), `PARSE-UNCLOSED-BLOCK` (reached `EOF` before `end`), `PARSE-TOP-LEVEL-STATEMENT`, `PARSE-CHAINED-COMPARISON`, `PARSE-INVALID-ASSIGNMENT-TARGET`. The message for a `NAME` followed by another expression token (`puts "hello"`) should name the missing newline and mention that calls need parentheses.

### Phase 2 checklist

- [x] Define AST nodes for declarations, statements, types, and expressions; retain source spans.
- [x] Parse top-level function and struct declarations, parameters, fields, and type applications.
- [x] Parse bindings, returns, `if`/`elsif`/`else`, `while`, and `for` blocks, using `end` rather than indentation.
- [x] Parse literals, lists, named struct construction, function calls, fields, indexes, grouping, and operators with the specified precedence and associativity.
- [x] Reject chained comparisons, executable top-level statements, and syntax outside the core grammar.
- [x] Report syntax errors with locations and stable error codes.
- [x] Show the parsed tree from the CLI so a sample file is inspectable.

### Focused tests

- Valid: `examples/hello.agc`, and the `classify` and `Task`/`for` programs from section 10.
- Precedence and associativity: `a + b * c`, `a - b - c`, `-a * b`, `not a and b`, `a or b and c`.
- Postfix: `user.name`, `users[0]`, `find_user(1).name`.
- Calls and constructors: `main()`, positional arguments, `Task(done: false, title: "x")`, trailing commas.
- Types: `List[Int]`, `List[List[Int]]`, `x: List[String] = []`.
- Spans: a chosen node's line and column match the source.
- Errors: chained comparison, top-level statement, missing `end`, bare `TYPE_NAME`, index/field assignment, missing newline after a statement, `puts "hello"`.

**Complete when:** the valid examples in section 10 parse into a tree with spans, and invalid syntax is rejected with a `PARSE-*` diagnostic and a location, without exposing host parser errors.

## Phase 3: Name resolution and type checking

Turn the tree from Phase 2 into a checked program, or a located check diagnostic. Keep the same shape: `check` takes the `program` `parse` returned and gives back the program or one diagnostic, and stops at the first error. No evaluator yet.

### `src/` organization for this phase

```text
src/
├── main.rkt       # CLI: lex, parse, check, show the tree or the first diagnostic
├── source.rkt     # unchanged
├── diagnostic.rkt # unchanged
├── token.rkt      # unchanged
├── lexer.rkt      # unchanged
├── ast.rkt        # unchanged
├── parser.rkt     # unchanged
└── checker.rkt    # program -> program or check diagnostic

tests/
├── lexer-test.rkt   # unchanged
├── parser-test.rkt  # unchanged
└── checker-test.rkt # focused checker behavior tests
```

Keep the checker free of parsing rules and evaluator rules. Do not add an evaluator file, and do not add placeholder checks for enums, generics, or modules.

### Types and the check result

- One internal type value covers every type: the symbols `Int`, `Float`, `Bool`, `String`, and `Nil`; `(list 'List T)`; and `(list 'Struct NAME)`. No new struct is needed.
- `check` returns the same `program` when it is valid, or one diagnostic. It does not annotate the tree and adds no new result type. Phase 4 can read the types again if it needs them.
- The parser already stores decoded literals, so the checker dispatches on the Racket value: integer → `Int`, flonum → `Float`, string → `String`, boolean → `Bool`, `'nil` → `Nil`.
- An empty list takes its type from the expected type: an annotation, a parameter, a field, the function result, or an argument position. With no expected type it is an error.

### Diagnostic codes

Use the `CHECK-` prefix, one code per rule family. Fold cases that read the same into one code.

- `CHECK-UNKNOWN-NAME` — a name that is not a local, a parameter, a function, or `puts`.
- `CHECK-UNKNOWN-TYPE` — a type name that is not a primitive, `List`, or a declared struct, or `List` with the wrong number of arguments.
- `CHECK-REDEFINED-NAME` — a duplicate function, struct, parameter, or field, or a definition of the reserved `puts`.
- `CHECK-ARITY` — a call with the wrong number of arguments.
- `CHECK-TYPE-MISMATCH` — operand, condition, argument, assignment, return, or field value of the wrong type.
- `CHECK-EMPTY-LIST-TYPE` — an empty list with no expected type.
- `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`, `CHECK-MISSING-FIELD` — constructor field rules.
- `CHECK-NOT-A-STRUCT` — field access on a non-struct; `CHECK-NOT-A-LIST` — index on a non-list.
- `CHECK-SHADOWED-NAME` — a new local reusing a name visible in an outer scope.
- `CHECK-ANNOTATION-ON-EXISTING` — an annotation on a name that is already bound.
- `CHECK-IMMUTABLE-ASSIGNMENT` — an assignment to the `for` variable.
- `CHECK-MISSING-RETURN` — a non-`Nil` function with a path that does not return.
- `CHECK-MAIN` — no `main`, or a `main` that is not `() -> Nil`. A second `main` is a duplicate name and is `CHECK-REDEFINED-NAME`.

### Work sequence

1. Add `src/checker.rkt` with one entry point `(check program)`, a `bail`/`return` escape, a `fail` that builds a diagnostic from a span, and a `type->string` for messages.
2. Pass 1 registers declarations before any body: a struct table (name → ordered fields and types) and a function table (name → parameter types and result type). Register `puts(value: String) -> Nil` first so it cannot be redefined. Reject duplicate names and unknown types here.
3. Pass 2 checks bodies with a scope stack: a list of frames, each a hash of name → type, plus helpers `lookup`, `introduce!` (no-shadowing), and `update!`.
4. Add `check-expression` with an optional expected type: literals, `name-ref`, `unary`, `binary`, `call`, `construct`, `list-lit`, `field-access`, `index-access`.
5. Add `check-statement`: `binding`, `return-stmt`, `expr-stmt`, `if`, `while`, `for`. Each control block pushes and pops a frame.
6. Add return analysis: `block-returns?` is true when every statement on the path returns; an `if` returns when it has an `else` and every branch returns; loops never guarantee a return. A non-`Nil` function must return on every reachable path.
7. Add the program rule: exactly one `main() -> Nil` with no parameters, and `puts` reserved.
8. Wire `main.rkt`: after `parse`, call `check` behind a `diagnostic?` guard, and print the tree when it passes.
9. Add `tests/checker-test.rkt`; update the Phase 3 checklist and the development skill. CI needs no change: `raco test tests/` finds the new file.

### Checker rules and edge cases

- Numeric operators: `+` takes two numbers of the same type or two `String`s; `-`, `*`, `/` take two numbers of the same type; `%` takes two `Int`s; `<`, `<=`, `>`, `>=` take two numbers of the same type; `==` and `!=` take two values of the same primitive type (no list or struct equality); `and`, `or`, and `not` take `Bool`; unary `-` takes a number. No implicit numeric conversion.
- `if` and `while` conditions must be `Bool`.
- Calls: the name must be a function or `puts`, the arity must match, and each argument is checked against its parameter type. Named arguments are only for constructors.
- Constructors: the type must be a declared struct; every field appears exactly once, in any order; no unknown and no duplicate fields; each value matches the field type.
- Field access needs a struct target and a field that exists. Index needs a `List[T]` target and an `Int` index. Strings cannot be indexed.
- A binding with an annotation introduces a new local. A binding without an annotation that names a visible variable is an update and must keep the type; otherwise it introduces a local in the current scope.
- No-shadowing: a new local may not reuse a name visible in an outer scope. An annotation on an existing name is `CHECK-ANNOTATION-ON-EXISTING`.
- The `for` variable is a fresh binding in the loop body and cannot be assigned. A parameter may be assigned; the spec only forbids the `for` variable.
- An empty list needs an expected type. A non-empty list checks each element against the expected element type when one is known, and otherwise against the first element's type.
- `return` with no value is `Nil`; a value must match the function result type.
- Stop at the first error and return one diagnostic, as the other stages do. No error recovery.
- Every check diagnostic points at the node span: the name token for names, the operator token for operators, the whole node otherwise.

### Open decisions

Defaults are chosen so work can start; change the spec first if a different answer is wanted.

1. `check` returns the same `program`. Add a typed tree only when Phase 4 needs it.
2. A parameter may be reassigned; only the `for` variable is fixed.
3. Statements after a `return` are allowed and not diagnosed. Add `CHECK-UNREACHABLE` only if asked.
4. Every program needs one `main() -> Nil`, as the spec says. A file of only structs fails, and a test helper must wrap a body in `main`.
5. A second `main` is caught as a duplicate function name (`CHECK-REDEFINED-NAME`) before the `main` rule runs, so `CHECK-MAIN` only covers a missing or wrongly typed `main`.

### Phase 3 checklist

- [x] Register structs and functions before checking bodies so forward calls and recursion work.
- [x] Check primitive, struct, and `List[T]` types; infer local variable types and require an expected type for empty lists.
- [x] Enforce operator operand types, boolean conditions, call arity, constructor fields, and field/index access rules.
- [x] Implement lexical block scopes, assignment updates, immutable types, and the no-shadowing rule.
- [x] Check return types and require every reachable path in non-`Nil` functions to return.
- [x] Require exactly one `main() -> Nil` with no parameters and reserve `puts`.
- [x] Show the checked result from the CLI so a valid file is inspectable end to end.

### Focused tests

- Valid: `examples/hello.agc`, the `classify` and `Task`/`for` programs from section 10, a forward call, and a recursive function.
- Rejected from section 10: `age: Int = "25"` and `if 1` are `CHECK-TYPE-MISMATCH`; `values = []` is `CHECK-EMPTY-LIST-TYPE`; `puts "hello"` stays a parse error.
- Names and types: unknown name, unknown type, `List` with the wrong arity, duplicate function or struct, redefined `puts`.
- Calls and constructors: wrong arity, unknown field, missing field, duplicate field, wrong field value type.
- Statements: assignment that changes a type, annotation on an existing name, shadowed local, field access on a non-struct, index on a non-list.
- Returns and entry: missing return on one branch, missing `main`, two `main`s, `main` with parameters, `main` with a non-`Nil` result.
- Spans: line and column of a type mismatch and of an unknown name.

**Complete when:** valid programs pass, the rejected examples in section 10 fail for the intended reason, and each failure points to its source.

## Phase 4: Core evaluator

Run the checked `program` and produce a value, or one located runtime diagnostic. Keep the stage shape: `evaluate` takes the `program` `check` returned and returns a value or one `diagnostic`. The evaluator trusts the checker: it does not re-check types, and every name it looks up is expected to be bound. It still never raises a host exception and never prints.

### `src/` organization for this phase

```text
src/
├── main.rkt       # CLI: lex, parse, check, evaluate
├── source.rkt     # unchanged
├── diagnostic.rkt # unchanged
├── token.rkt      # unchanged
├── lexer.rkt      # unchanged
├── ast.rkt        # unchanged
├── parser.rkt     # unchanged
├── checker.rkt    # unchanged
└── evaluator.rkt  # program -> value or runtime diagnostic

tests/
├── lexer-test.rkt    # unchanged
├── parser-test.rkt   # unchanged
├── checker-test.rkt  # unchanged
└── evaluator-test.rkt # focused evaluator behavior tests
```

Keep the evaluator free of parsing and checking rules. Do not add a bytecode or VM layer; the AST is the program.

### Runtime values and the result

- `Int`, `Float`, `Bool`, `String` map to the Racket integer, flonum, boolean, and string values. `Nil` is the symbol `'nil`. `List[T]` is a Racket list (the checker guarantees homogeneity).
- A struct instance is a new `instance` struct in `evaluator.rkt`: the declared type name plus an immutable hash from field name to value. Field order comes from the `struct-decl` in the program, so no separate table from the checker is needed.
- `evaluate` returns the value of the initial `main()` call. Since `main` is `() -> Nil`, a successful run returns `'nil`; `puts` is the visible output.
- The evaluator writes `puts` output to `(current-output-port)`, so tests capture it with `parameterize` and `with-output-to-string`.

### Environment and control flow

- A scope stack is a list of frames, each a mutable hash from name to a box, so assignment mutates a binding without changing its type. Helpers: `lookup`, `define!` for a fresh local, and `assign!` for an existing binding. The checker already rejects unknown names and shadowing.
- `exec-block` runs statements in order and stops on `return`. Use one `let/ec` per function call as the return escape: `return-stmt` calls it with the value, so returns leave loops and nested blocks without a signal value threaded through every statement.
- Functions are registered before any body runs, so forward calls and recursion work. Calling a function pushes a frame with its parameters and evaluates the body under the return escape.
- `if`/`elsif`/`else` take the first true branch; `while` re-evaluates its condition each pass; `for` binds its variable to each element in list order in a fresh scope.
- Bindings: an annotation or a fresh name introduces a local; a binding without an annotation to a visible name updates that binding. An assignment statement updates the visible binding.

### Numeric and list rules

- Evaluate operands, arguments, and constructor fields left to right.
- `and` and `or` short-circuit and produce `Bool`; `not` negates. No truthiness.
- `+` is `string-append` for `String`, and numeric addition otherwise. `-`, `*`, `/` follow the checker's same-type rule.
- `Int` is signed 64-bit: after `+`, `-`, or `*` on two `Int`s, reject a result outside `[-2^63, 2^63-1]` as `RUNTIME-INTEGER-OVERFLOW`. Racket integers are unbounded, so this is an explicit range check.
- `/` on `Int` truncates toward zero (Racket `quotient`); `/` on `Float` is IEEE 754. A zero divisor is `RUNTIME-DIVISION-BY-ZERO` for both `Int` and `Float` (Racket would return infinity for floats). `%` is `Int` only and uses `remainder`, matching `a = (a / b) * b + (a % b)` with truncated division; a zero divisor is the same error.
- `<`, `<=`, `>`, `>=` compare two numbers of the same type. `==` and `!=` compare two values of the same primitive type with `equal?`, so a NaN is not equal to itself as IEEE 754 requires.
- Index access rejects an index outside `0` to `length - 1` as `RUNTIME-INDEX-OUT-OF-RANGE`; negative indexes are out of range.
- Field access reads the instance hash; the checker guarantees the struct and field exist.
- A `list-lit` evaluates its elements in order into a Racket list; an empty list is `'()`.

### Runtime diagnostic codes

Use the `RUNTIME-` prefix, one code per failure family. Point the span at the operator for arithmetic, and at the index expression for a bounds error.

- `RUNTIME-DIVISION-BY-ZERO` — `/` or `%` with a zero divisor.
- `RUNTIME-INTEGER-OVERFLOW` — an `Int` operation outside 64-bit range.
- `RUNTIME-INDEX-OUT-OF-RANGE` — a list index below zero or at or above the length.

Add a catch-all `RUNTIME-UNREACHABLE` only as a guard that turns an unexpected evaluator state into a diagnostic instead of a traceback; the checker should make it unreachable.

### Work sequence

1. Add `src/evaluator.rkt` with `evaluate`, an `instance` struct, a `bail` that escapes with a `diagnostic`, and a `let/ec` per call for `return`.
2. Register the struct declarations (name → ordered fields) and the function declarations before running anything.
3. Add `eval-expression`: literals, `name-ref`, `unary`, `binary`, `call`, `construct`, `list-lit`, `field-access`, `index-access`.
4. Add `exec-statement` and `exec-block`: `binding`, `return-stmt`, `expr-stmt`, `if`, `while`, `for`, with scope push/pop and assignment.
5. Add the numeric helpers: same-type dispatch, the 64-bit range check, truncated integer division, `remainder` for `%`, and the zero-divisor check for both numeric types.
6. Implement `puts` (write the string and a newline) and call `main()` once with no arguments.
7. Wire `main.rkt`: after `check`, call `evaluate` behind a `diagnostic?` guard and exit 1 with the formatted runtime diagnostic; on success exit 0. Keep the checked tree printable for inspection (Phase 5 decides the flag).
8. Add `tests/evaluator-test.rkt`; CI needs no change because `raco test tests/` finds the new file.

### Evaluator rules and edge cases

- The evaluator is total: every expression the checker accepted produces a value or a `RUNTIME-*` diagnostic. No Racket exception may escape, including a division by zero or an out-of-range index.
- `main` is the only entry point; a program of only declarations cannot run, and Phase 3 already requires one `main() -> Nil`.
- `for` over an empty list runs its body zero times; `while` with a false condition runs zero times.
- A function that reaches the end of a `Nil` body returns `'nil`; a non-`Nil` function cannot reach the end because the checker required a return on every path.
- Constructor named arguments may be written in any order; evaluate them in source order and store them by name, so field order in the hash does not matter.
- An assignment to a `for` variable is already `CHECK-IMMUTABLE-ASSIGNMENT`; the evaluator does not need a second guard.

### Phase 4 checklist

- [ ] Evaluate expressions and arguments left to right; implement short-circuit `and` and `or`.
- [ ] Execute scoped blocks, assignments, returns, conditionals, loops, and `for` over lists.
- [ ] Evaluate function calls, structs, fields, lists, and indexes according to the checked types.
- [ ] Implement numeric rules, integer overflow checks, division and modulo behavior, zero-division errors, and list bounds errors.
- [ ] Implement `puts(value: String) -> Nil` and start each program by calling `main()`.
- [ ] Convert runtime failures into Agentica diagnostics rather than host tracebacks.

### Focused tests

- Valid: `examples/hello.agc`, the `classify` and `Task`/`for` programs from section 10, a forward call, and a recursive function.
- Control flow: `if`/`elsif`/`else` selection, `while` counting, `for` over a non-empty and an empty list, and an early `return` inside a loop.
- Values: integer, float, string, boolean, and `nil` literals; list literals; struct construction, field access, and index access.
- Operators: short-circuit `and`/`or` (a side effect in the skipped operand does not run), string concatenation, truncated integer division with negative operands, and `remainder` sign.
- Runtime errors: integer overflow, division by zero for `Int` and `Float`, `%` by zero, and an index equal to and one past the length.
- Output: `puts` writes the value and one newline to the captured port; a run returns `'nil`.
- Spans: the line and column of a division-by-zero and of an out-of-range index.

**Complete when:** the section 10 programs that pass checking execute with the specified results and runtime errors are located in the source.

## Phase 5: CLI and diagnostic quality

Make the pipeline usable from the command line and make every diagnostic name the file, position, stable code, concrete explanation, and the offending source text. Presentation stays in `main.rkt` and `diagnostic.rkt`; the stages keep returning data.

### `src/` organization for this phase

```text
src/
├── main.rkt       # full pipeline driver plus CLI flags
├── source.rkt     # unchanged
├── diagnostic.rkt # format-diagnostic gains the source excerpt and caret
├── token.rkt      # unchanged
├── lexer.rkt      # unchanged
├── ast.rkt        # unchanged
├── parser.rkt     # unchanged
├── checker.rkt    # unchanged
└── evaluator.rkt  # unchanged

tests/
├── lexer-test.rkt     # unchanged
├── parser-test.rkt    # unchanged
├── checker-test.rkt   # unchanged
├── evaluator-test.rkt # unchanged
├── diagnostic-test.rkt # excerpt and caret formatting
└── examples-test.rkt   # every grammar example, valid and invalid

examples/
├── hello.agc          # existing
├── classify.agc       # section 10 function and control flow
└── tasks.agc          # section 10 lists and field access
```

No new pipeline module: the CLI is `main.rkt`, and the excerpt logic is one helper in `diagnostic.rkt`.

### Diagnostic format

Replace the single-line format with the grammar's section 9 shape: a header with file, line, column, and code; the explanation; and the source line with a caret run under the span.

```text
hello.agc:4:11 error[CHECK-TYPE-MISMATCH]
Expected Int, found String.

4 | age: Int = "25"
  |           ^^^^
```

- The caret run starts at the span's column and spans `end - start` characters, clamped to the line's text so a multi-line or EOF span cannot print past the end.
- Split the source text on newlines and take line `line - 1`; strip a trailing `\r` so CRLF files do not print a stray carriage return.
- `format-diagnostic` keeps returning one string; `main.rkt` prints it to stderr.
- The grammar's `E_TYPE_MISMATCH` style codes are proposals. Keep the existing stage-prefixed codes (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`) so the tests and the skill stay consistent, and note the choice in the roadmap if the grammar later fixes `E_` names.

### CLI behavior

- Default: read the UTF-8 file, run lexer → parser → checker → evaluator, print `puts` output, exit 0. Print the first diagnostic to stderr and exit 1.
- `--dump` (or the minimal equivalent) prints the checked tree instead of running it, preserving the Phase 3 inspection path.
- A missing file or bad usage prints one plain CLI message and exits 2; it is not a stage diagnostic. Wrap the file read so a missing file never prints a Racket traceback.
- Keep the driver thin: one `fail!` helper prints a diagnostic and exits 1, and each stage is guarded with `diagnostic?` before the next.

### Work sequence

1. Add the excerpt helper to `src/diagnostic.rkt` and rewrite `format-diagnostic`; the stage tests only use it inside failure messages, so no assertion depends on the old layout.
2. Add the CLI flags and the missing-file handling in `src/main.rkt`; wire `evaluate` as the final stage.
3. Add `examples/classify.agc` and `examples/tasks.agc` from section 10.
4. Add `tests/diagnostic-test.rkt`: header line, caret column and width, CRLF handling, and a span at the end of a line.
5. Add `tests/examples-test.rkt`: run each valid example and assert success plus expected output; run each rejected fragment and assert its code (`CHECK-TYPE-MISMATCH`, `CHECK-EMPTY-LIST-TYPE`, `PARSE-*` for `puts "hello"`).
6. Update `.github/workflows/ci.yml` to smoke-test both valid examples, and update the Phase 5 checklist and the development skill.
7. Carry-over from the Phase 3 review: operator spans. `unary` and `binary` keep no operator token, so `CHECK-TYPE-MISMATCH` on `1 + "a"` points at the whole expression, not at `+`. Add an operator span field to `unary`/`binary` in `ast.rkt`, set it in `parser.rkt`, and use it in `check-unary`/`check-binary` in `checker.rkt` (and the evaluator's arithmetic errors). Update the parser and checker tests that build or match these nodes.
8. Carry-over from the Phase 3 review: `checker.rkt` reports unreachable internal cases (unsupported expression, unary operator, operator, statement) as `CHECK-UNKNOWN-TYPE`, which is misleading if it ever fires. Give them their own code (`CHECK-INTERNAL`), as the evaluator does with `RUNTIME-UNREACHABLE`.

### Phase 5 checklist

- [ ] Run `.agc` files through the lexer, parser, checker, and evaluator from the command line.
- [ ] Show stable error codes, file, line, column, a concrete explanation, and a source excerpt with a caret.
- [ ] Cover syntax, unknown names, type mismatches, arity, struct fields, missing returns, and runtime errors with focused examples.
- [ ] Check every valid and invalid example in the grammar against the interpreter.
- [ ] Point operator diagnostics at the operator token, not the whole expression.
- [ ] Report unreachable checker states with a dedicated `CHECK-INTERNAL` code instead of `CHECK-UNKNOWN-TYPE`.

### Focused tests

- Formatting: the header has file, 1-based line and column, and the code; the caret run matches the span width; the excerpt line matches the source; CRLF and end-of-line spans are safe.
- CLI: a valid file exits 0 and prints the program output; each stage's failure exits 1 with one diagnostic; a missing file exits 2 without a traceback.
- Examples: every valid program in section 10 runs; every rejected fragment fails with the intended code and a useful position.
- Regression: `raco test tests/` still passes with the new format, and `racket src/main.rkt examples/hello.agc` still exits 0.

### Open decisions

1. Keep the stage-prefixed codes rather than the grammar's `E_*` proposals until the grammar fixes the final names.
2. Exit 1 for any stage diagnostic, 2 for CLI usage or a missing file.
3. `--dump` is the only inspection flag; add token or AST dumps only if a debugging need appears.

**Complete when:** a user can run the sample from the README and get useful diagnostics for the grammar's required failure cases.

## Phase 6: Validate the language design

- [ ] Ask agents to write and repair small programs using only the grammar and examples.
- [ ] Record correct programs, repair attempts, and whether diagnostics helped identify the fix.
- [ ] Use the results to revise the grammar and examples explicitly before adding exceptions to the implementation.

**Complete when:** the prototype provides evidence about whether Agentica's syntax and diagnostics help agents write and repair programs.

## Later extensions

- [ ] Decide variant name resolution and generic inference before implementing enums and pattern matching.
- [ ] Add enum construction, `case`/`in`, exhaustiveness checks, and unreachable-arm diagnostics as one extension across lexer, parser, checker, evaluator, and diagnostics.
- [ ] Define normative designs for modules, interpolation, error propagation, generics, methods, FFI, async, or actors before implementing them.

These items are deliberately outside the initial core milestone.
