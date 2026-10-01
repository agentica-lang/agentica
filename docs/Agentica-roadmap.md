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
- `CHECK-NOT-A-STRUCT` — field access on a non-struct; `CHECK-NOT-INDEXABLE` — index on something that is not a list or a map.
- `CHECK-SHADOWED-NAME` — a new local reusing a name visible in an outer scope.
- `CHECK-ANNOTATION-ON-EXISTING` — an annotation on a name that is already bound.
- `CHECK-IMMUTABLE-ASSIGNMENT` — an assignment to the `for` variable.
- `CHECK-MISSING-RETURN` — a non-`Nil` function with a path that does not return.
- `CHECK-MAIN` — no `main`, or a `main` that is not `() -> Nil`. A second `main` is a duplicate name and is `CHECK-REDEFINED-NAME`.
- `CHECK-INT-RANGE` — an `Int` literal above 2^63-1. `-9223372036854775808` is valid: the literal 2^63 is allowed as the direct operand of unary `-`.

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

- [x] Evaluate expressions and arguments left to right; implement short-circuit `and` and `or`.
- [x] Execute scoped blocks, assignments, returns, conditionals, loops, and `for` over lists.
- [x] Evaluate function calls, structs, fields, lists, and indexes according to the checked types.
- [x] Implement numeric rules, integer overflow checks, division and modulo behavior, zero-division errors, and list bounds errors.
- [x] Implement `puts(value: String) -> Nil` and start each program by calling `main()`.
- [x] Convert runtime failures into Agentica diagnostics rather than host tracebacks.

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

- [x] Run `.agc` files through the lexer, parser, checker, and evaluator from the command line.
- [x] Show stable error codes, file, line, column, a concrete explanation, and a source excerpt with a caret.
- [x] Cover syntax, unknown names, type mismatches, arity, struct fields, missing returns, and runtime errors with focused examples.
- [x] Check every valid and invalid example in the grammar against the interpreter.
- [x] Point operator diagnostics at the operator token, not the whole expression.
- [x] Report unreachable checker states with a dedicated `CHECK-INTERNAL` code instead of `CHECK-UNKNOWN-TYPE`.

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

## Phase 5b: Maps and builtin modules

Add `Map[K, V]` before Phase 6, so the validation does not measure a missing dictionary. This is a core extension: the spec in `Agentica-gramatica.md` changed first (type table, `map_literal`, qualified call, the `Map` and `List` modules).

- Maps are immutable like lists. Keys are `Int` or `String`. A literal is `{"a": 1}`; `m[key]` reads; a missing key is `RUNTIME-KEY-NOT-FOUND`; a duplicate literal key keeps the last value.
- Operations are builtin modules, not global functions: `Map.has_key?`, `Map.keys`, `Map.size`, `Map.put`, `List.size`. `Map.keys` returns keys in insertion order.
- The parser keeps a qualified call as one dotted name in `call-name`; `check-builtin-call` in the checker types the builtins generically and the evaluator dispatches them in `eval-call`.
- New codes: `CHECK-MAP-KEY-TYPE`, `RUNTIME-KEY-NOT-FOUND`. `m[k] = v` stays `PARSE-INVALID-ASSIGNMENT-TARGET`, now with a hint to use `Map.put`.

### Phase 5b checklist

- [x] Lex `{` and `}` as delimiters that suppress newlines.
- [x] Parse map literals and qualified calls such as `Map.put(...)`.
- [x] Check `Map[K, V]` types, map literals, `m[key]`, and the `Map`/`List` builtins.
- [x] Evaluate maps with insertion order and located missing-key errors.
- [x] Add `examples/inventory.agc` and cover each stage with a focused test.

## Phases 5c to 5h: Standard library before validation

Phase 6 measures whether agents can write useful programs, so the language needs I/O, strings, and data exchange first. These are core extensions. As in Phase 5b, write the spec in `Agentica-gramatica.md` first (planned syntax lives in its section 8 until the phase lands, then moves to sections 4–6), then implement stage by stage.

Rules for every phase here:

- Names and shapes copy Ruby and Elixir, so an agent can guess them: modules (`IO`, `String`, `JSON`, `TCP`, `HTTP`) called as `Module.function(...)`, snake_case functions, `?` suffix for predicates (`String.contains?`), `!` suffix for a version that halts on failure (`String.to_int!`). The lexer must accept a trailing `?` or `!` on a function name (see Open decisions).
- Modules are builtin and typed specially in `check-builtin-call`, like `Map` and `List`. No user modules yet. Add no Racket dependencies: `racket/base`, `racket/tcp`, `net/http-client`, `openssl`, and `json` all ship with Racket.
- All I/O goes through Racket's `current-input-port` and `current-output-port` (or the matching port parameters), so tests can inject it. Tests never touch the real network: use a local listener on port 0.
- A function that can fail has two forms once Phase 5e lands: `x(...)` returns `Result[T]`, `x!(...)` halts with a `RUNTIME-` diagnostic. Before 5e only the halting `!` form exists.

### Phase 5c: String library

```text
String.length(s: String) -> Int
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
```

- Length and slice count Unicode characters, not bytes. The grammar keeps "no slices, no string indexing"; `String.slice` is a function, not syntax.
- String conversions accept decimal notation with an optional sign. Invalid text is `RUNTIME-INVALID-NUMBER`; an integer outside the signed 64-bit range is `RUNTIME-INTEGER-OVERFLOW`. Splitting on an empty separator returns one Unicode character per list element.
- `String.slice` out of range is `RUNTIME-INDEX-OUT-OF-RANGE`.

- [x] Allow a trailing `?` and `!` in function names (lexer; spec in the grammar's section 8, move it to sections 4–6 when done). The suffix counts only when the next character is `(`, so `a!=b` still lexes as `a != b`.
- [x] Reserve `String` as a type and module name.
- [x] Type and evaluate the functions above, with a focused test per stage.
- [x] Add `examples/strings.agc`.

### Phase 5d: Standard input and output

```text
IO.puts(value: String) -> Nil
IO.print(value: String) -> Nil
IO.warn(value: String) -> Nil
IO.inspect(value: T) -> T
IO.gets() -> String
IO.read() -> String
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Nil
```

- `puts` stays as a global alias of `IO.puts`.
- `IO.warn` writes to standard error. `IO.inspect` prints any value in a stable debug form (structs, lists, maps) and returns it, like Elixir.
- `IO.gets` returns the next line without the newline, and halts with `RUNTIME-END-OF-INPUT` at end of input; check `IO.eof?()` first. This changes to `Result` in 5e.
- `System.exit` ends the run with that exit code. The evaluator returns it as data, and only `main.rkt` exits.
- `main.rkt` passes the program arguments to the evaluator.

- [x] Evaluator takes input and output ports and the argument list as parameters.
- [x] Type and evaluate the functions above.
- [x] Add `examples/echo.agc` and a test that feeds input through a string port.

### Phase 5e: Result and error handling

Phases 5f to 5h need a way to report failure without halting. Full enums and generics stay a later extension, so `Result[T]` is a builtin generic type, special-cased in the checker like `List` and `Map`.

```text
Result[T]                         # either ok(value) or error(message)
ok(value: T) -> Result[T]
error(message: String) -> Result[T]
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String
```

- The error is always a `String`. A richer error type waits for enums.
- Add the non-bang forms from 5c and 5d: `String.to_int`, `String.to_float`, `IO.gets` return `Result[...]`.
- `Result.unwrap!` on an error is `RUNTIME-UNWRAP-ERROR`.
- Open decision: use `Result.ok?` or add pattern matching (`case r in ok(v)`) with the enum extension. Start with the functions.

- [ ] Add the `Result[T]` type, `ok`, `error`, and the `Result` module.
- [ ] Reserve `Result`, `ok`, `error`.
- [ ] Add the Result forms to `String` and `IO`.
- [ ] Add `examples/result.agc`.

### Phase 5f: JSON

JSON comes before the network phases because it is pure and easy to test. Add an opaque builtin type `Json`.

```text
JSON.parse(s: String) -> Result[Json]
JSON.encode(value: T) -> String
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
JSON.list(j: Json) -> Result[List[Json]]
```

- `JSON.encode` accepts `Int`, `Float`, `Bool`, `String`, `Nil` (as `null`), `List`, `Map[String, V]`, structs (as objects, fields in declared order), and `Json`. A map with `Int` keys is a `CHECK-` error.
- No user generics are needed. Struct decoding needs a type as an argument, which the checker special-cases like the other builtins (see 5f2).

- [ ] Add the `Json` type and the `JSON` module.
- [ ] Use Racket's `json` library, without new dependencies.
- [ ] Add `examples/json.agc`.

### Phase 5f2: Typed JSON decoding

```text
JSON.decode(s: String, type: T) -> Result[T]
```

The second argument is a struct name, not a value, as in `JSON.decode(text, User)`. This is similar to Go's `json.Unmarshal` into a typed target, or Elixir's `struct(User, map)`. The checker types the call as `Result[User]`, and the evaluator walks the declared fields.

- The target type may contain only `Int`, `Float`, `Bool`, `String`, `List[T]`, `Map[String, V]`, and other structs. Anything else is `CHECK-NOT-DECODABLE`, reported before the program runs.
- Fields map to JSON keys by name. Struct tags such as Go's `json:"user_name"` are out of scope.
- A missing field or a wrong type is `error("age: expected Int, found String")`, with the path to the field. Extra keys are ignored.
- A JSON integer decodes to `Float` when the field is `Float`, but a JSON float never decodes to `Int`.

- [ ] Parse a bare type name as an expression (spec in the grammar's section 8; today it is `PARSE-UNEXPECTED-TOKEN`, so update that parser test), and make the checker accept it only as an argument of `JSON.decode` and `JSON.schema`.
- [ ] Check that the target type is decodable.
- [ ] Decode nested structs, lists, and maps, with the path in error messages.
- [ ] Add a round-trip test: `JSON.encode` then `JSON.decode` gives back the same field values (compare fields, since structs have no `==`).

### Phase 5g: TCP

Opaque builtin types `Socket` and `Listener`. Every blocking call takes a timeout in milliseconds, so a program cannot hang an agent forever.

```text
TCP.connect(host: String, port: Int, timeout: Int) -> Result[Socket]
TCP.listen(port: Int) -> Result[Listener]
TCP.accept(listener: Listener, timeout: Int) -> Result[Socket]
TCP.send(socket: Socket, data: String) -> Result[Nil]
TCP.recv(socket: Socket, max: Int, timeout: Int) -> Result[String]
TCP.read_line(socket: Socket, timeout: Int) -> Result[String]
TCP.close(socket: Socket) -> Nil
TCP.local_port(listener: Listener) -> Int
```

- `TCP.listen(0)` picks a free port; `TCP.local_port` reports it, so tests can run a client and a listener in one program without a fixed port.
- Sockets close when the run ends, even after a halting error.
- Strings are UTF-8. Binary data is out of scope.

- [ ] Add `Socket` and `Listener` types and the `TCP` module.
- [ ] Test with a local listener on port 0. No outside network in tests or CI.
- [ ] Add `examples/tcp_echo.agc`.

### Phase 5h: HTTP and HTTPS

A client only. `Response` is a builtin struct with fields `status: Int`, `body: String`, `headers: Map[String, String]`, so `response.status` works with the existing field access.

```text
HTTP.get(url: String) -> Result[Response]
HTTP.post(url: String, body: String, headers: Map[String, String]) -> Result[Response]
HTTP.request(method: String, url: String, body: String, headers: Map[String, String]) -> Result[Response]
```

- `http://` and `https://` both work; HTTPS uses Racket's `openssl` and verifies certificates. A bad certificate is an `error`, not a halt.
- A fixed default timeout, with a limit on the body size.
- Builtin structs are new: the checker needs to know their fields. Keep it to `Response`.
- Tests talk to a local HTTP server written in Racket in the test file. A Node fixture (see "Integration fixtures in Node.js") adds an independent server. HTTPS is covered by one test against a local self-signed server that must be rejected.

- [ ] Support builtin structs in the checker (`Response` only).
- [ ] Add the `HTTP` module over `net/http-client`.
- [ ] Add `examples/http_get.agc`. CI does not run it, because it needs the network.

### Open decisions

- Whether `?` and `!` become part of function names for all functions or only for builtin modules. Recommended: all functions, as in Ruby and Elixir.
- ~~Whether `Map.has` and `Map.len` get renamed to `Map.has_key?` and `Map.size`.~~ Decided in 5c: renamed, together with `List.len` → `List.size`.
- A capability flag for the CLI (`--allow-net`, `--allow-read`): agents run unknown programs, and network access should be opt-in. Decide before 5g.

### Integration fixtures in Node.js (optional layer)

The Racket-only tests stay the base: they are fast and need nothing installed. On top of them, small Node.js fixtures check interoperability, because a server written independently of the client catches mistakes that both sides would share (chunked bodies, header case, JSON-RPC line framing).

- Fixtures live in `tests/fixtures/*.js` and use only Node's standard library (`http`, `https`, `net`, `readline`). No `npm install`, no `package.json`.
- A fixture listens on port 0 and prints the port as its first line of standard output. The Racket test starts it with `racket/subprocess`, reads the port, runs the Agentica program against it, and kills the process at the end.
- The test finds Node with `find-executable-path` and skips itself, with a visible message, when Node is missing. `raco test tests/` must pass without Node.
- CI uses the Node that ships on the runner. Add no setup step unless the version causes trouble.
- The fixtures are tests only. They are not part of the language and add no Racket dependency.
- A test against the official MCP SDK needs `npx` and the network. Keep it manual and out of CI.
- An `.agc` example that starts a fixture with `Process.spawn` (5l) is allowed as a demo, but CI does not run it.

Where it applies: 5g (TCP echo server), 5h (HTTP and HTTPS server, including a self-signed certificate to reject), 5l (a child process to spawn), 5m (a hand-written stdio MCP server to run the Agentica client against, and an Agentica server checked by a Node client).

### Checklist for phases 5c to 5h

- [x] Phase 5c: String library.
- [x] Phase 5d: standard input and output.
- [ ] Phase 5e: `Result[T]` and error handling.
- [ ] Phase 5f: JSON.
- [ ] Phase 5f2: typed JSON decoding.
- [ ] Phase 5g: TCP.
- [ ] Phase 5h: HTTP and HTTPS.

## Phases 5i to 5m: MCP support

Goal: write an MCP client and an MCP server in Agentica. MCP is JSON-RPC 2.0 over stdio (one JSON message per line) or Streamable HTTP. Do stdio first. The first client and server are plain example programs, which also give Phase 6 real material. Add `require` or modules only if those examples get too big to read.

### Phase 5i: JSON builders and schemas

A JSON-RPC reply needs JSON built at run time, not only read.

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(j: Json) -> Bool
JSON.schema(type: T) -> Json
```

- `JSON.from` accepts the same types as `JSON.encode`.
- `JSON.schema(AddArgs)` takes a struct name, as in `JSON.decode`, and returns its JSON Schema (`type`, `properties`, `required`). MCP tools declare an `inputSchema`, so a tool is a struct plus a function.
- Same decodable-type rule as 5f2: `CHECK-NOT-DECODABLE` otherwise.

- [ ] Add the functions above and a focused test for each stage.
- [ ] Add a test that `JSON.schema` output matches a fixed string for one struct.

### Phase 5j: Function values

A server registers tools with handlers, so functions must be passable. Keep it small: named functions only, no closures that capture variables.

```ruby
def add(args: Json) -> Result[Json]
  ...
end

handlers: Map[String, Fn[Json, Result[Json]]] = {"add": &add}
result = handlers["add"].call(args)
```

- New type `Fn[A, ..., R]`, with the last argument as the return type. `&name` makes a value from a top-level function (like Ruby's `&method(:name)`, shortened). `.call(...)` calls it, as in Ruby. The grammar's section 8 already specifies both.
- The checker compares parameter and return types exactly. A wrong shape is `CHECK-TYPE-MISMATCH`.
- Reserve `Fn`. Lambdas and closures stay a later extension.

- [ ] Lex `&`, and parse `Fn[...]` types, `&name`, and `.call(...)`.
- [ ] Check and evaluate function values.
- [ ] Add `examples/dispatch.agc`.

### Phase 5k: Error propagation

Chains such as connect, initialize, list tools, call, each returning `Result`, nest deeply without help.

- Decide the form first: Ruby-like `try!`, Elixir-like `with`, or a Rust-like `?` suffix. Recommended: a `try` expression, `value = try Result.something()`, that returns the error from the enclosing function, which must itself return `Result[...]`.
- A `try` in a function that does not return `Result` is a `CHECK-` error.
- Update the grammar first, then all stages.

- [ ] Pick the form and write it in `Agentica-gramatica.md`.
- [ ] Implement it across the lexer, parser, checker, and evaluator.
- [ ] Add a focused test per stage and rewrite one earlier example to use it.

### Phase 5l: Process spawning

An MCP client for stdio servers has to launch the server and use its stdin and stdout.

```text
Process.spawn(command: String, args: List[String]) -> Result[Process]
Process.send(p: Process, data: String) -> Result[Nil]
Process.read_line(p: Process, timeout: Int) -> Result[String]
Process.close(p: Process) -> Nil
```

- Opaque `Process` type. Every blocking call has a timeout, as in 5g.
- Processes are killed when the run ends.
- Needs the capability flag `--allow-run`, off by default (see Open decisions above).
- The child's standard error goes to the parent's standard error.

- [ ] Add the `Process` type and module over `racket/subprocess`.
- [ ] Test with a small child program, not an outside tool.

### Phase 5m: MCP examples

- [ ] `examples/mcp_server.agc`: a stdio server that answers `initialize`, `tools/list`, and `tools/call` for one or two tools. Logs go to standard error with `IO.warn`, so standard output carries only protocol messages.
- [ ] `examples/mcp_client.agc`: spawns the server above, initializes, lists tools, and calls one.
- [ ] A test that runs the client against the server and checks the result.
- [ ] Node fixtures (see "Integration fixtures in Node.js"): the Agentica client against a Node stdio server, and a Node client against the Agentica server. Skipped when Node is missing.

### Later, for MCP

- HTTP server and streaming responses (SSE) for Streamable HTTP, after 5h.
- Concurrency, so a client can handle notifications while it waits. A sequential loop is enough at first.
- `Time`, `Random`, UUID, Base64, and a Ruby-style `Regex`.

### Checklist for phases 5i to 5m

- [ ] Phase 5i: JSON builders and schemas.
- [ ] Phase 5j: function values.
- [ ] Phase 5k: error propagation.
- [ ] Phase 5l: process spawning.
- [ ] Phase 5m: MCP client and server examples.

## Phase 6: Validate the language design

- [ ] Ask agents to write and repair small programs using only the grammar and examples.
- [ ] Record correct programs, repair attempts, and whether diagnostics helped identify the fix.
- [ ] Use the results to revise the grammar and examples explicitly before adding exceptions to the implementation.

**Complete when:** the prototype provides evidence about whether Agentica's syntax and diagnostics help agents write and repair programs.

## Later extensions

- [ ] Faster maps: `mapping` in `src/evaluator.rkt` is an association list, so `Map.put`, `Map.has_key?`, and `m[key]` are O(n) and building a map of n entries is O(n²). Replace it with an immutable `hash` plus a reversed key list (insertion order), keeping `mapping-put` as the only writer. Do this when JSON or HTTP payloads (phases 5f–5h) make maps large.
- [ ] Decide variant name resolution and generic inference before implementing enums and pattern matching.
- [ ] Add enum construction, `case`/`in`, exhaustiveness checks, and unreachable-arm diagnostics as one extension across lexer, parser, checker, evaluator, and diagnostics.
- [ ] Define normative designs for modules, interpolation, error propagation, generics, methods, FFI, async, or actors before implementing them.

- [ ] No structural unions (`Int | String`): they need flow-sensitive narrowing and duplicate the exhaustiveness work of enums. Sum types come from enums. After Phase 6, decide whether agents need a builtin `Option[T]` (special-cased like `Result[T]`) for nullable values.

These items are deliberately outside the initial core milestone.
