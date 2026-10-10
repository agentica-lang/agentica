# Agentica implementation roadmap

This roadmap turns the core specification in [`grammar.md`](grammar.md) into a usable interpreter. Planned syntax lives in [`future.md`](future.md) until its phase lands. Keep every phase focused on the core in sections 4–6 until the prototype can run and diagnose the examples in sections 7–8. Enums were kept out of the initial milestone and are now implemented as a later extension.

## Current implementation order

The core interpreter, Results, JSON primitives, function values, lightweight
tasks, BDD, TCP/TLS/HTTP, files/paths, strict Void, and processes are implemented. The next priority is general
programming: useful standalone programs first, larger applications next, then
MCP. Historical phase numbers below remain stable; this order governs pending
work rather than their numeric order.

| Order | Next work | Outcome |
|---|---|---|
| 1 | **Complete:** Everyday library (remaining 5n plus strings, conversions, time and randomness) | Write useful scripts without rebuilding basic helpers |
| 2 | **Complete:** Typed JSON (5f2) and builders/schemas (5i) | Handle structured input and construct replies |
| 3 | **Complete:** Modules and imports, including embedded `std/` and external `pkg/` resolution | Split larger programs across files |
| 4 | Real applications | Validate the APIs with a file-processing CLI, automation script and HTTP service |
| 5 | MCP examples (5m), then Streamable HTTP | Build protocol clients and servers on the proven foundations |
| 6 | **Next:** Ruby-style ergonomics: operators, methods on builtins, interpolation, blocks and closures | Accept the Ruby habits agents already have, with static types |
| 7 | Bytecode VM in C with the Boehm GC (phase 7) | Run checked programs much faster, with the same output and diagnostics |

After steps 1–2, target everyday scripts and automation. After steps 3–5,
target larger general-purpose programs. Keep diagnostics, behavior tests,
grammar, and the self-contained programming reference part of every phase.
Specify new APIs in `future.md` before implementation; move them into the
grammar only when they land. Detailed pending work appears after the completed
foundations below.

Historical phase sections retain their original completion signatures. The
current language uses Void for completion and Nil for data; grammar.md and
the programming reference contain the current signatures.

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

Keep source positions and token/diagnostic data separate from lexing rules. `main.rkt` remains a thin driver; no general pipeline module is needed until multiple stages are connected. Use Racket's built-in test support (`rackunit`) as the test framework; add no third-party libraries or test frameworks. Independent integration counterparts may use Node.js, Python, or curl as described below and in `AGENTS.md`.

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
- NL handling: skip stray `NL` tokens between declarations, between statements, and before `EOF`. Each LF/CRLF outside delimiters emits NL, including blank/comment lines; the parser tolerates the extra tokens. Phase 5d2 aligned the docs without changing accepted programs.
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

- Valid: `examples/hello.agc`, and the `classify` and `Todo`/`for` programs from section 8.
- Precedence and associativity: `a + b * c`, `a - b - c`, `-a * b`, `not a and b`, `a or b and c`.
- Postfix: `user.name`, `users[0]`, `find_user(1).name`.
- Calls and constructors: `main()`, positional arguments, `Todo(done: false, title: "x")`, trailing commas.
- Types: `List[Int]`, `List[List[Int]]`, `x: List[String] = []`.
- Spans: a chosen node's line and column match the source.
- Errors: chained comparison, top-level statement, missing `end`, bare `TYPE_NAME`, index/field assignment, missing newline after a statement, `puts "hello"`.

**Complete when:** the valid examples in section 8 parse into a tree with spans, and invalid syntax is rejected with a `PARSE-*` diagnostic and a location, without exposing host parser errors.

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
- `CHECK-UNKNOWN-METHOD` — a method that the receiver's type does not have (this replaced `CHECK-NOT-A-STRUCT`); `CHECK-NOT-INDEXABLE` — index on something that is not a list or a map.
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

- Valid: `examples/hello.agc`, the `classify` and `Todo`/`for` programs from section 8, a forward call, and a recursive function.
- Rejected from section 8: `age: Int = "25"` and `if 1` are `CHECK-TYPE-MISMATCH`; `values = []` is `CHECK-EMPTY-LIST-TYPE`; `puts "hello"` stays a parse error.
- Names and types: unknown name, unknown type, `List` with the wrong arity, duplicate function or struct, redefined `puts`.
- Calls and constructors: wrong arity, unknown field, missing field, duplicate field, wrong field value type.
- Statements: assignment that changes a type, annotation on an existing name, shadowed local, field access on a non-struct, index on a non-list.
- Returns and entry: missing return on one branch, missing `main`, two `main`s, `main` with parameters, `main` with a non-`Nil` result.
- Spans: line and column of a type mismatch and of an unknown name.

**Complete when:** valid programs pass, the rejected examples in section 8 fail for the intended reason, and each failure points to its source.

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

- Valid: `examples/hello.agc`, the `classify` and `Todo`/`for` programs from section 8, a forward call, and a recursive function.
- Control flow: `if`/`elsif`/`else` selection, `while` counting, `for` over a non-empty and an empty list, and an early `return` inside a loop.
- Values: integer, float, string, boolean, and `nil` literals; list literals; struct construction, field access, and index access.
- Operators: short-circuit `and`/`or` (a side effect in the skipped operand does not run), string concatenation, truncated integer division with negative operands, and `remainder` sign.
- Runtime errors: integer overflow, division by zero for `Int` and `Float`, `%` by zero, and an index equal to and one past the length.
- Output: `puts` writes the value and one newline to the captured port; a run returns `'nil`.
- Spans: the line and column of a division-by-zero and of an out-of-range index.

**Complete when:** the section 8 programs that pass checking execute with the specified results and runtime errors are located in the source.

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
├── classify.agc       # section 8 function and control flow
└── tasks.agc          # section 8 lists and field access
```

No new pipeline module: the CLI is `main.rkt`, and the excerpt logic is one helper in `diagnostic.rkt`.

### Diagnostic format

Replace the single-line format with the grammar's section 7 shape: a header with file, line, column, and code; the explanation; and the source line with a caret run under the span.

```text
hello.agc:4:11 error[CHECK-TYPE-MISMATCH]
Expected Int, found String.

4 | age: Int = "25"
  |           ^^^^
```

- The caret run starts at the span's column and spans `end - start` characters, clamped to the line's text so a multi-line or EOF span cannot print past the end.
- Split the source text on newlines and take line `line - 1`; strip a trailing `\r` so CRLF files do not print a stray carriage return.
- `format-diagnostic` keeps returning one string; `main.rkt` prints it to stderr.
- Keep the stage-prefixed codes (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`). The grammar used to propose `E_TYPE_MISMATCH` style names; it now documents the stage-prefixed ones.

### CLI behavior

- Default: read the UTF-8 file, run lexer → parser → checker → evaluator, print `puts` output, exit 0. Print the first diagnostic to stderr and exit 1.
- `--dump` (or the minimal equivalent) prints the checked tree instead of running it, preserving the Phase 3 inspection path.
- A missing file or bad usage prints one plain CLI message and exits 2; it is not a stage diagnostic. Wrap the file read so a missing file never prints a Racket traceback.
- Keep the driver thin: one `fail!` helper prints a diagnostic and exits 1, and each stage is guarded with `diagnostic?` before the next.

### Work sequence

1. Add the excerpt helper to `src/diagnostic.rkt` and rewrite `format-diagnostic`; the stage tests only use it inside failure messages, so no assertion depends on the old layout.
2. Add the CLI flags and the missing-file handling in `src/main.rkt`; wire `evaluate` as the final stage.
3. Add `examples/classify.agc` and `examples/tasks.agc` from section 8.
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
- Examples: every valid program in section 8 runs; every rejected fragment fails with the intended code and a useful position.
- Regression: `raco test tests/` still passes with the new format, and `racket src/main.rkt examples/hello.agc` still exits 0.

### Open decisions

1. Keep the stage-prefixed codes; the grammar documents them.
2. Exit 1 for any stage diagnostic, 2 for CLI usage or a missing file.
3. `--dump` is the only inspection flag; add token or AST dumps only if a debugging need appears.

**Complete when:** a user can run the sample from the README and get useful diagnostics for the grammar's required failure cases.

## Phase 5b: Maps and builtin modules

Add `Map[K, V]` before Phase 6, so the validation does not measure a missing dictionary. This is a core extension: the spec in `grammar.md` changed first (type table, `map_literal`, qualified call, the `Map` and `List` modules).

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

Phase 6 measures whether agents can write useful programs, so the language needs I/O, strings, and data exchange first. These are core extensions. As in Phase 5b, write the spec first (planned syntax lives in `future.md` until the phase lands, then moves to sections 4–6 of `grammar.md`), then implement stage by stage.

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

- [x] Allow a trailing `?` and `!` in function names (lexer; now in sections 4–6 of `grammar.md`). Phase 5d2 decoupled suffix recognition from `(`; `!` followed by `=` remains an operator, so `a!=b` still lexes as `a != b`.
- [x] Reserve `String` as a type and module name.
- [x] Type and evaluate the functions above, with a focused test per stage.
- [x] Add `examples/strings.agc`.

### Phase 5d: Standard input and output

```text
IO.puts(value: String) -> Nil
IO.print(value: String) -> Nil
IO.warn(value: String) -> Nil
IO.inspect(value: T) -> T
IO.gets() -> Result[String]
IO.gets!() -> String
IO.read() -> String
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Nil
```

- `puts` stays as a global alias of `IO.puts`.
- `IO.warn` writes to standard error. `IO.inspect` prints any value in a stable debug form (structs, lists, maps) and returns it, like Elixir.
- Final API (5d2 + 5e): IO.gets returns Result[String], with an error at EOF; IO.gets! returns a line without its newline and halts with RUNTIME-END-OF-INPUT at EOF. The Result-dependent 5d2 item landed with 5e, not as a temporary API.
- `System.exit` ends the run with that exit code. The evaluator returns it as data, and only `main.rkt` exits.
- `main.rkt` passes the program arguments to the evaluator.

- [x] Evaluator takes input and output ports and the argument list as parameters.
- [x] Type and evaluate the functions above.
- [x] Add `examples/echo.agc` and a test that feeds input through a string port.

### Historical order (after the static review of `cd33a26`)

Measure before growing the language. The order from here is: 5d2 (consistency fixes) → 5d3 (agent API) → 6a (first agent evaluation) → 5e with `try` (Result and propagation together) → faster maps → 5f (JSON) → 6b (second evaluation) → the rest (5f2, 5g, 5h, 5i, 5j, 5l, 5m). Each later phase should answer a problem seen in 6a or 6b.

This records the earlier sequence. The current implementation order above
supersedes its ordering of remaining phases.

### Phase 5d2: Consistency fixes (P0)

The spec and the implementation must agree, because an agent that reads both learns the contradiction. Reproduce each item as a failing test first, then fix it.

- [x] Separate suffix recognition from call syntax: `String.contains? ("a", "a")` and whitespace in declarations work; `a!=b` remains `a != b`. Regression reproduced before the fix. Function values still wait for 5j.
- [x] Align the newline contract with emission: one NL per LF/CRLF outside delimiters, including blank/comment lines. Kept scanner/parser acceptance unchanged and tested the exact token sequence.
- [x] Add CHECK-EMPTY-MAP-TYPE for an untyped empty map; lists keep CHECK-EMPTY-LIST-TYPE. Regression reproduced before the fix.
- [x] Clean `grammar.md`: removed "no implementation yet", the native runtime notes, and the old decisions; planned syntax moved to `future.md`; the docs were renamed to `grammar.md`, `roadmap.md`, and `future.md`.
- [x] Close IO.gets -> Result[String] and IO.gets! -> String with 5e. Migrated all existing String-consuming example/evaluation callers, preserving intentional starter bugs.
- [x] Add optional --max-steps N / RUNTIME-STEP-LIMIT, counting expression/statement entries including repeated loop conditions. Empty infinite loops are bounded and counts reset per evaluation. No default limit or blocking-I/O timeout; existing evaluation subprocess timeouts remain.
- [x] Document O(n) list indexing and prefer for traversal; no list representation change.

### Phase 5d3: Agent API (P0 and P1)

`--dump` prints Racket structures, which is a poor interface for an agent. Add small machine-readable commands. Start with a stable JSON shape; presentation stays in `main.rkt`.

```text
agentica check program.agc --ai                # compact text for the agent (first)
agentica check program.agc --json              # parse and check, never run
agentica symbols program.agc --json            # functions, structs, fields, signatures
agentica show program.agc --symbol NAME --json # one declaration with its span and source
agentica refs program.agc --symbol NAME --json # uses of a symbol
```

Diagnostic shape (P0):

```json
{"code": "CHECK-TYPE-MISMATCH", "message": "expected Int, found String",
 "file": "program.agc",
 "range": {"start": {"line": 2, "column": 14}, "end": {"line": 2, "column": 18}},
 "expected": "Int", "actual": "String"}
```

- `expected` and `actual` are fields the checker produces, not text cut from the message. Diagnostics that have no such data omit them.
- No persistent symbol IDs yet: symbol name + location + file hash is enough. Structured patches wait until real cases need them.
- `check --ai` and `check --json` exit 1 on a diagnostic and 0 on success, like the plain CLI.

`--ai` is the first output to build (KISS for v0.0.1): compact text for the agent that reads the result and repairs the code. `--json` stays for tools that need to deserialize. Both print the same structured diagnostic; only the printer differs, so presentation can change without duplicating logic.

```text
check failed: 1 error

[CHECK-TYPE-MISMATCH]
  at: main.agc:12:10
  in: greet(name: String) -> String
  source: return 42
  expected: String
  actual: Int
```

```text
[CHECK-ARG-TYPE]
  at: main.agc:8:20
  source: String.split(text, 3)
  callee: String.split(text: String, separator: String) -> List[String]
  argument: 2 (separator)
  expected: String
  actual: Int
```

On success it prints `check ok`.

- Fixed format, spaces only (no tabs): stable code in brackets, exact location, the signature of the enclosing function (`in:`), the minimal relevant source fragment, and the error's own fields (`expected`, `actual`, `symbol`, `callee`, `argument`).
- Add `suggestion:` only when the checker has a grounded fix. Never guess.
- Open question: `CHECK-ARG-TYPE` is not an existing code (argument mismatches are `CHECK-TYPE-MISMATCH` today). Split it only if 6a shows agents gain from it.
- Compact text is not proven to help the agent or to save tokens. Measure it in 6a (`--ai` against plain text and `--json`); the defensible gain is choosing relevant information and keeping it predictable.

- [x] `agentica check <file>` subcommand: checks, prints `check ok`, never runs (plain diagnostics; `--ai` and `--json` come next).
- [x] Add optional `expected`, `actual`, `callee`, `labels`, and `help` to `diagnostic`; the checker fills them in `CHECK-TYPE-MISMATCH` and the plain-call `CHECK-ARITY` and records the enclosing function signature. (Builtin-call arity now fills callee from the 5e catalog; add an argument field only when a call-argument mismatch fills it.)
- [x] One structured diagnostic, three printers: plain (with labels and help), `--ai`, and `--json`. They print to stderr, like the plain form.
- [x] Grounded suggestions in `help`: nearest name (variables, functions, fields, types), field list, missing field type, String/Int/Float conversion functions, missing `return`, shadowing, `for` variable assignment. Builtin-name suggestions now use the 5e catalog.
- [ ] Measure with the `binary` arm (`docs/eval-6a.md`) whether `--ai` and labels cut failing runs and tokens.
- [ ] `symbols`, `show`, `refs` (P1).
- [ ] One test per command over `examples/`.

Diagnostics from evaluation data (`docs/eval-diagnostics.md`, `tests/eval/diagnostics.py`):

- [x] Count the diagnostics agents saw in past runs, with messages, source lines and repeats.
- [x] Fix the stale Int/Float help: it now names `Float.from_int` and `Float.to_int!`.
- [ ] Map common Python, Ruby and JavaScript habits (`len`, `str`, `print`, `range`, `input`, `Int.to_float`, `!`, `&&`, `||`, `+=`, `None`) to the Agentica form in `help`.
- [ ] Suggest the module function for method-call style on builtin types (`s.length`, `x.to_i()`, `xs.append(v)`).
- [ ] Fix the misleading `elif` and `None` messages.
- [ ] Re-run the `binary` arm and the script to measure the change.

### Phase 6a: First agent evaluation

Run a small evaluation now, with the language as it is, and again after 5e and 5f (6b). The agent should implement Agentica, and also be the subject of the experiment.

Tasks (about five, each with hidden tests):

1. Write a function from a description.
2. Repair a type error.
3. Change a struct and every use of it.
4. Implement an algorithm with lists and maps.
5. Fix a program with scope and return errors.

Method: the same model, equivalent tasks, and a comparable budget in Agentica and Python. Measure hidden tests passed, repair attempts, tokens, and time, and separate syntax errors from logic errors. Record whether the checker output was enough to fix the error, comparing the three formats: plain, `--ai`, and `--json`.

The agent runs the `agentica` binary (`dist/agentica`), not `racket src/main.rkt`. `dist/` is not versioned and can be stale, so the runner rebuilds it with `make exe` before each round and puts it on the `PATH`.

The skill `.agents/skills/agentica-programming/` is a variable: one arm gets `docs/grammar.md` and `examples/`, the other gets only the skill, which is self-contained: its `references/language.md` is a minimal English subset of the language, and the agent does not read the grammar. It starts without a list of commonly broken rules, on purpose: first see how agents behave with the basic skill, then add rules only for failures actually observed. Record the skill version (commit) used in each round.

- [x] Write the minimal `agentica-programming` skill.
- [x] Write the task set and hidden tests under `tests/eval/` (data and a runner script; no new dependency).
- [x] Run the Agentica and Python arms (round 1, DeepSeek V4.1 flash via `pi`) and record the results in `docs/eval-6a.md`.
- [x] Add the `binary` arm (no skill, no grammar) and a Firejail sandbox; smoke-tested. A full `binary` round is still to run.
- [ ] Sonnet 5.5 round: postponed; only `pi` for now.
- [x] List the problems found and put them in the next phases before building more (list building: 5n).

### Phase 5e: Result and error handling (with propagation)

Phases 5f to 5h needed a way to report failure without halting. At that point, user enums were still planned; `Result[T]` shipped as a builtin generic type, special-cased in the checker like `List` and `Map`. Generic user enums have since landed under Later extensions. Error propagation (`try`, formerly Phase 5k) shipped in the same delivery.

```text
Result[T]                         # either ok(value) or error(message)
ok(value: T) -> Result[T]
error(message: String) -> Result[T]
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String
```

- The builtin `Result[T]` error payload remains a `String`; user-defined enums are available for domain-specific error types.
- Add the non-bang forms from 5c and 5d: `String.to_int`, `String.to_float`, `IO.gets` return `Result[...]`.
- `Result.unwrap!` on an error is `RUNTIME-UNWRAP-ERROR`.
- Use Result.ok? and module functions; matching stays deferred. Result.message is empty text for success. unwrap_or evaluates both arguments eagerly. error needs an expected Result type (CHECK-RESULT-TYPE); try outside a Result-returning function is CHECK-TRY-CONTEXT.

Propagation rule: `try` unwraps an `ok` or returns the `error` from the current function, and is allowed only inside a function that returns `Result[...]` (otherwise a `CHECK-` error). `Result` errors stay Strings; there are no language exceptions.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

- [x] Add Result[T], ok, error, and the Result module with contextual typing and explicit runtime tags.
- [x] Reserve Result, ok, error, try.
- [x] Add Result forms to String and IO, retaining bang codes and injected ports.
- [x] Specify try in future.md, then implement across lexer, parser, checker, and evaluator and move it into grammar.md. Both language references are updated.
- [x] Add examples/result.agc using try; examples/classify.agc now parses text through a Result-returning helper and preserves adult output.

### Builtins catalog

src/builtins.rkt is the shared table of builtin names, arities, parameter types, signatures/type-rule tags, implementation keys, effects, and descriptions. Generic typing and implementation functions remain in their stages; no plugin framework or general type solver.

- Each entry has: name, type rule or signature, effects (`stdin`, `stdout`, `net`, `process`), and a short description. Implementations stay normal functions.
- The checker, the evaluator, and `agentica help NAME --json` read the same table; effects are information only at first (no mandatory annotations).
- [x] Catalogue 5b–5e builtins in src/builtins.rkt.
- [x] Checker and evaluator resolve the same entries; every catalog entry has a real checked program with independent expected output.
- [x] Add agentica help NAME --json, with no source file required and exit 2 for unknown targets. Trailing --json also works after leading options; the CLI regression was reproduced before the fix.

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
- Generic user enums landed later; generic functions and structs remain unsupported. Struct decoding needs a type as an argument, which the checker special-cases like the other builtins (see 5f2).

- [x] Add the `Json` type and the `JSON` module.
- [x] Use Racket's `json` library, without new dependencies.
- [x] Add `examples/json.agc`.

Implemented in `src/json.rkt` (opaque wrapper and strict input guards), the builtin catalog, checker, and evaluator. Parsing and scalar escaping use Racket's library; no parser/AST changes. Access and extraction return Results, Int extraction checks signed 64-bit bounds, and Float extraction checks finiteness. Encoding recursively rejects Results and Int-keyed maps at check time, preserves declared struct/map order, and halts on non-finite Floats with `RUNTIME-JSON-ENCODE`. Parsed object order is unspecified. Tests cover malformed/trailing input, Unicode, null/false, wrong kinds, bounds, recursive encoding eligibility, ordered output, round trips, `try`, and CLI diagnostics. Typed decoding and builders remain in 5f2/5i.

### Stdio transport primitives (after 5f)

- [x] Add `IO.read_bytes(count: Int) -> Result[List[Int]]`, `IO.flush() -> Nil`, and `String.from_bytes(data: List[Int]) -> Result[String]`, using Racket's native port/byte functions and existing catalog typing. Keep IO.read's all-text-until-EOF behavior; no Bytes type, syntax, or dependency additions.
- [x] Specify byte-counted reads: wait for count bytes or EOF, accept short/empty EOF success, zero consumes nothing, invalid counts consume nothing. A fixed 1 MiB per-call cap bounds eager allocation; larger streams use multiple reads. Decode UTF-8 strictly only once complete bytes are available. Read/conversion failures return Results.
- [x] Keep `IO.eof?` as a blocking, non-consuming EOF check using peek-byte, not a readiness poll or UTF-8 character peek. Explicit stdout flush does not close ports or flush stderr; blocking stdio still has no timeout.
- [x] Test byte/character boundaries, invalid counts/UTF-8, mixed text/byte reads, and live pipe replies while stdin stays open. The pipe test fails with a no-op flush or a peek-char EOF mutation; both were restored and rechecked. Update grammar and both skills.

### Phase 5g: TCP and TLS

Implemented after the lightweight tasks and evaluator isolation in phase 5j2.
The normative API is in grammar.md, section "TCP, TLS and HTTP/1.1".

- [x] Opaque Socket and Listener handles with explicit and automatic cleanup.
- [x] TCP.connect/listen/accept/send/send_bytes/recv_bytes/read_line/close/close_listener/local_port.
- [x] Positive full-operation deadlines, independent read/write locks, UTF-8 lines and bounded byte streams.
- [x] Verified TLS clients and PEM-configured TLS listeners using Racket OpenSSL.
- [x] Independent Node TCP/TLS counterparts on localhost port zero, required in CI.
- [x] Add examples/tcp_echo.agc.

### Phase 5h: HTTP/1.1 and HTTPS clients and servers

The normative signatures, options and lifetime rules live in grammar.md and
the self-contained programming reference. HTTP/1.0 is not implemented.

- [x] Builtin Header, Request, Response and client/server options records, plus opaque client/server/body/writer handles.
- [x] Racket-only HTTP/1.1 framing over TCP/TLS, with fixed lengths, chunked streams, trailers, informational responses and 100 Continue.
- [x] Explicit client pools, keep-alive, bounded acquisition/operation deadlines and body sizes; no transparent retries or redirects.
- [x] Progressive uploads and response reads, with context-taking supervised upload producers.
- [x] Concurrent connection handlers with isolated scopes, shared global budget and explicit server wait/close.
- [x] Verified HTTPS in both directions; local test CA, rejection without trust and hostname validation.
- [x] Independent Node clients/servers, actual persistent-connection checks, full-duplex progress, invalid framing and cleanup checks.
- [x] Add examples/http_get.agc and examples/http_server.agc. Network examples require a local counterpart; integration tests exercise the same APIs through the CLI.

### Open decisions

- Whether `?` and `!` become part of function names for all functions or only for builtin modules. Recommended: all functions, as in Ruby and Elixir.
- ~~Whether `Map.has` and `Map.len` get renamed to `Map.has_key?` and `Map.size`.~~ Decided in 5c: renamed, together with `List.len` → `List.size`.
- Network and filesystem access use host permissions without a separate capability flag.

### Independent integration fixtures

TCP/HTTP interoperability tests use a protocol implementation independent of the Agentica component under test, so a shared client/server bug cannot satisfy both sides of the test. These tests are required in CI. Racket-only tests may complement them; they are not a required base layer. Keep `rackunit` as the test framework, with Node.js, Python, or curl as counterpart tools.

- Fixtures live in `tests/fixtures/` and use standard libraries only: for example Node's `http`, `https`, `net`, and `readline`, or Python's HTTP and socket modules. Add no third-party libraries or test frameworks.
- Tests stay hermetic: localhost, dynamically assigned ports (port 0), and no external services. A server fixture reports its assigned port after listening; the Racket test starts it with `racket/subprocess`, waits for readiness, runs the Agentica program against it, and cleans up processes, ports, and resources on every exit. Client fixtures wait for the Agentica server's readiness in the same way.
- Find the chosen tool with `find-executable-path`. Local runs may skip with a visible message when it is missing; CI must fail rather than skip.
- CI installs Node 24 for the selected TCP/TLS/HTTP/HTTPS standard-library fixtures; no npm packages are needed.
- The fixtures are tests only. They are not part of the language and add no Racket dependency.
- A test against the official MCP SDK needs `npx` and the network. Keep it manual and out of CI.
- An `.agc` example that starts a fixture with `Process.spawn` (5l) is allowed as a demo, but CI does not run it.

Where it applies: 5g (TCP counterpart), 5h (HTTP/HTTPS counterparts, including a self-signed certificate to reject), 5l (a child process to spawn), 5m (an independent stdio MCP server to run the Agentica client against, and an Agentica server checked by an independent client).

### Checklist for phases 5c to 5h

- [x] Phase 5c: String library.
- [x] Phase 5d: standard input and output.
- [x] Phase 5d2: consistency fixes (Result-dependent I/O landed with 5e).
- [ ] Phase 5d3: agent API (`check --json`, `symbols`, `show`, `refs`).
- [x] Phase 6a: first agent evaluation (round 1 done; see `docs/eval-6a.md`).
- [x] Phase 5e: Result[T], try, and the builtins catalog.
- [x] Faster maps (before JSON).
- [x] Phase 5f: JSON.
- [x] Stdio transport primitives: counted bytes, strict UTF-8 decoding, flush, and byte-oriented EOF.
- [x] Phase 5f2: typed JSON decoding.
- [x] Phase 5g: TCP and TLS.
- [x] Phase 5h: HTTP/1.1 and HTTPS clients and servers.

## Completed foundations for general programming and MCP

### Phase 5j: Function values

A server registers tools with handlers, so functions must be passable. Keep it small: named functions only, no closures that capture variables.

```ruby
def add(args: Json) -> Result[Json]
  ...
end

handlers: Map[String, Fn[Json, Result[Json]]] = {"add": &add}
result = handlers["add"].call(args)
```

- New type `Fn[A, ..., R]`, with the last argument as the return type. `&name` makes a value from a top-level function (like Ruby's `&method(:name)`, shortened). `.call(...)` calls it, as in Ruby. `future.md` already specifies both.
- The checker compares parameter and return types exactly. A wrong shape is `CHECK-TYPE-MISMATCH`.
- Reserve `Fn`. Lambdas and closures stay a later extension.

- [x] Lex `&`, and parse `Fn[...]` types, `&name`, and `.call(...)`.
- [x] Check and evaluate function values. Exact parameter/return matching, first-class named references in containers/fields/arguments/returns, no closures or JSON encoding; inspect is `<Fn>`.
- [x] Add `examples/dispatch.agc`.

### Executable BDD features

- [x] Parse an English Gherkin subset in `.feature` files: Background, Scenario/Example, Scenario Outline/Examples, steps, Doc Strings, Data Tables, tags and locations. Unsupported syntax fails explicitly.
- [x] Add `agentica test` and `BDD.run(...)->Result[Json]`, deterministic predefined steps and typed Agentica handlers registered with `BDD.step(..., &handler)`.
- [x] Execute independent scenarios with fresh state and local processes. Assertion/runtime/timeout failures stop only the current scenario; missing/ambiguous steps and assertion-free Then steps fail; remaining steps are reported as not executed.
- [x] Bound execution/output and clean up processes and ports on all exits. Run native process integration with `make test` and verify the compiled CLI with `make test-bdd` in CI; no container preparation or runtime distribution.
- [x] Cover flushed replies before EOF, failure continuation, outline arguments/state, no-flush timeout, exact output/exit checks, and blocked-process cleanup. Document the catalog, report verdict and host execution in `docs/bdd.md` and both development/programming skills.

### Phase 5j2: Lightweight I/O concurrency

Implement before TCP and HTTP, using Racket coroutine threads. No scheduler, closures, channels or CPU parallelism.

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Nil
```

- [x] Separate shared immutable program tables from task-local scopes, depth and return/diagnostic escapes; extract runtime values and task supervision into separate Racket modules.
- [x] Add typed task results, repeated awaits, nonnegative sleep and a synchronized global --max-steps budget. Any task diagnostic or System.exit terminates its evaluation, including unawaited failures.
- [x] Cancel tasks and close newly created resources at entrypoint return or external interruption while preserving borrowed ports.
- [x] Support BDD tasks, synchronize registration/state/assertions and independent input/output operations, reject pending tasks at handler return and preserve scenario continuation.
- [x] Rename the demonstration Task struct to Todo in examples, docs and tests; add examples/concurrency.agc and its CI smoke check.
- [x] Validate task results, scope isolation, blocked I/O, global failures/budget, cancellation and concurrent local BDD streams. Update grammar and both skills together.

### Phase 5k: Error propagation

Moved into Phase 5e: `try` ships together with `Result`. The decision is made: a `try` expression that returns the error from the enclosing function, which must return `Result[...]`. Nothing is left to do here.

### Phase 5n: Completed collection primitives

6a exposed the lack of list construction and sorting. The design is in `future.md` section 5. Primitive operations are now implemented through the builtins catalog (5e); only operations taking callbacks depend on 5j (function values). `List` is the chosen module, keeping `List.size` and avoiding an `Enum` module beside the implemented `enum` keyword.

- [x] Choose `List` as the collection module.
- [x] `List.append`, `List.set`, `List.repeat`, `List.reverse`: immutable operations with contextual generic typing and explicit index/count diagnostics. Keep the existing linked-list representation and document O(n) indexing/updates.
- [x] `Map.values`, `Map.get`, `Map.delete`: insertion-order traversal/deletion, Result lookup with two arguments, eager-default lookup with three. The catalog/checker/runtime/help share arity selection.
- [x] Algorithm examples and functional tests: open knight tours with degree-ordered backtracking; exact small traveling-salesman circuits with cost pruning. Validate complete paths and optimal costs rather than a particular route.
- [x] Map-based BFS maze example: distance and predecessor maps, numeric-keyed queue with deletion, and path reconstruction. Functional tests validate legal shortest paths, cycles, row boundaries, unreachable goals, start equal to goal, malformed inputs, and 32×32 grids. Map.delete remains O(n) for insertion-order maintenance.
- [x] Update grammar, programming reference, and development skill for these operations.

## Next work: General programming before MCP

### Completed: Strict Void prerequisite

- [x] Separate no-value completion from Nil data; require main() -> Void and explicit returns from Nil functions.
- [x] Reject Void in data type/value positions; support completion in Fn return types, Result[Void], and Task[Void].
- [x] Add ok() for successful Result[Void] completion; preserve ok(nil), JSON null, and Nil task results.
- [x] Migrate side-effect APIs, HTTP/BDD callbacks, shipped programs, benchmarks, and evaluation prompts/fixtures; update both language references and development notes.

### Completed: Files and paths

Make local data processing possible before adding more protocol-specific APIs.

- [x] Specify file and path APIs, error behavior and byte limits in `future.md`; use host filesystem permissions without a new capability flag.
- [x] Read and write text and bytes, including explicit overwrite/append behavior and strict UTF-8 decoding.
- [x] List directories, create directories, inspect file metadata, and join/resolve paths.
- [x] Cover failures and resource cleanup with temporary-directory integration tests; add a small file-processing example.

### Completed: Processes (phase 5l)

Run existing tools for automation, then reuse the same API for stdio MCP clients.

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
```

- Opaque evaluation-owned Process handles; literal argv, inherited environment and working directory.
- Positive full-operation deadlines and independent read/write locks. Active stream timeouts abort; lock and wait timeouts preserve children.
- Per-call 1 MiB limits, strict UTF-8 lines, counted bytes with short/empty EOF, and fixed-buffer stderr forwarding. Output has no lifetime cap; use Task for concurrent consumption.
- Direct children are killed and reaped on close, main return, System.exit, diagnostics, task failure, budget exhaustion, and external interruption. Arbitrary descendant trees remain outside the guarantee.
- --allow-run defaults off and propagates to tasks, HTTP callbacks, BDD handlers and programs under test. Check and help need no flag.

- [x] Specify exit-code retrieval, stdin closure, output limits, and deadline/cleanup behavior alongside spawn/send/read/close.
- [x] Add the Process type and module over racket/subprocess, without shell interpolation of command arguments.
- [x] Test independent local Node children, including nonzero exits, full-duplex I/O, cancellation, PID cleanup, BDD allowance, and source/compiled CLI behavior; require Node in CI.
- [x] Add examples/process-tool.agc, which runs racket --version and checks its Result and exit code; include it in CI with --allow-run.

### 1. Everyday library (remaining phase 5n and supporting utilities)

Function values are already available, so collection callbacks need no new
closure or scheduler feature. Keep names and argument order consistent with
the existing builtin library.

- [x] `List.concat`, `take`, `drop`, `at`: immutable operations, clamped nonnegative counts, and zero-based checked indexes.
- [x] Settle `reduce` argument order before implementing callbacks: accumulator first, `f(accumulator, item)`.
- [x] `List.map`, `filter`, `reduce`: exact callback signatures, ordered immutable traversal, contextual empty inputs, and shared execution limits.
- [x] `List.sort`, `sort_by`: stable ascending order over Int, Float or String (keys), NaN last, one key call per element.
- [x] Add string search/replacement and missing numeric conversions: `String.index_of/at/reverse/code/from_code` (`String.replace` already existed) and `Float.from_int`, `Float.to_int`, `Float.to_int!`.
- [x] Specify and add basic time and randomness APIs: `Time.now_ms` (wall clock), `Time.monotonic_ms`, inclusive `Random.int`, `Random.float` in [0, 1), a per-run generator seeded from the OS or `--seed N`.
- [ ] Decide which other gaps in `future.md` ("Other gaps for code-challenge programs": math, conversions, strings, sets, input, performance) belong here after a real task needs them.
- [ ] Add harder 6b model-evaluation tasks that need sorting.

**Milestone:** useful everyday scripts and automation using files, processes
and the basic library.

### 2. Typed JSON, builders and schemas

#### Phase 5f2: Typed JSON decoding

```text
JSON.decode(s: String, type: T) -> Result[T]
```

The second argument is a struct name, not a value, as in `JSON.decode(text, User)`. The checker types the call as `Result[User]`, and the evaluator walks the declared fields.

- The target type may contain only `Int`, `Float`, `Bool`, `String`, `List[T]`, `Map[String, V]`, and other structs. Anything else is `CHECK-NOT-DECODABLE`, reported before the program runs.
- Fields map to JSON keys by name. Struct tags such as Go's `json:"user_name"` are out of scope.
- A missing field or a wrong type is `error("age: expected Int, found String")`, with the path to the field. Extra keys are ignored.
- A JSON integer decodes to `Float` when the field is `Float`, but a JSON float never decodes to `Int`.

- [x] Parse a bare type name as an expression and accept it only in JSON type argument positions (JSON.decode and JSON.schema).
- [x] Check that the target type is decodable.
- [x] Decode nested structs, lists, and maps, with the path in error messages.
- [x] Add a round-trip test: `JSON.encode` then `JSON.decode` gives back the same field values (compare fields, since structs have no `==`).

#### Phase 5i: JSON builders and schemas

Construct structured output at run time, including future JSON-RPC replies.

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

- [x] Add the functions above and focused behavior tests.
- [x] Verify `JSON.schema` output against an independent expected schema for one struct.

### 3. Modules and imports

Split larger programs across files with explicit exports and predictable
resolution. This is planned language syntax, not an extension to implement
without a specification.

- [x] Define import/export syntax, module naming, path resolution and the entrypoint rule; normative rules now live in grammar.md.
- [x] Decide visibility, duplicate-name handling, import cycles and diagnostic spans across files.
- [x] Implement loading, checking and execution without resetting the execution's shared budget or resource ownership.
- [x] Test a program spanning multiple files and controlled diagnostics for missing imports, cycles and private names.

### 3a. Embedded standard library and external resolution

- [x] Reserve `std/` for embedded Agentica sources, retaining explicit import aliases.
- [x] Ship a String FIFO in `stdlib/queue.agc` without native queue dispatch.
- [x] Add `pkg/` search roots: entrypoint-local agc_libs, AGENTICA_PATH, user data, system data.
- [x] Validate paths and symlink containment; preserve module identities, source spans and BDD loading.
- [x] Verify queue behavior, precedence, compiled CLI and relocated release bundles.
- [x] Document imports/API in the grammar and programming reference together.

### 4. Real applications

Use complete programs to expose missing APIs before broadening the language.

- [ ] Build a file-processing CLI with useful error handling and structured output.
- [ ] Build a tool-running automation script that checks exits and cleans up children.
- [ ] Build a small HTTP service using typed JSON and modules.
- [ ] Add functional tests at each application's boundary and use Phase 6 agent evaluations to identify the next gaps.

**Milestone:** practical larger general-purpose programs, demonstrated by
these applications rather than a feature checklist alone.

### 5. MCP examples (phase 5m), then Streamable HTTP

Build stdio examples first on the file/process/JSON/module foundations. A
minimal protocol scaffold lives at `examples/mcp/stdio.agc`; it handles
`initialize`, `ping`, and an empty `tools/list`, but is not the planned tool
server yet.

- [x] Add the minimal `examples/mcp/stdio.agc` stdio scaffold with flushed JSON-RPC replies.
- [ ] `examples/mcp_server.agc`: a stdio server that answers `initialize`, `tools/list`, and `tools/call` for one or two tools. Logs go to standard error with `IO.warn`, so standard output carries only protocol messages.
- [ ] `examples/mcp_client.agc`: spawns the server above, initializes, lists tools, and calls one.
- [ ] A test that runs the client against the server and checks the result.
- [ ] Independent fixtures (see "Independent integration fixtures"): the Agentica client against an independent stdio server, and an independent client against the Agentica server. Required in CI; local runs may visibly skip when the chosen tool is missing.
- [ ] Specify dedicated SSE and Streamable HTTP behavior, then implement it over the existing HTTP/1.1 streaming APIs with independent interoperability tests.

Task concurrency is already available for handling notifications while a
client waits. Channels and `Process.poll_line` remain proposed in
[`future.md` section 8](future.md#8-concurrency-and-parallelism). UUID, Base64
and a Ruby-style `Regex` remain later utilities unless a real application
establishes an earlier need.

## Phase 6: Validate the language design

Phase 6a (first evaluation, before 5e) and 6b (second evaluation, after `Result` + `try` and JSON) are described under Phase 5d3 and use the same task set, so the results compare.

- [ ] Ask agents to write and repair small programs using only the grammar and examples.
- [ ] Record correct programs, repair attempts, and whether diagnostics helped identify the fix.
- [ ] Use the results to revise the grammar and examples explicitly before adding exceptions to the implementation.

**Complete when:** the prototype provides evidence about whether Agentica's syntax and diagnostics help agents write and repair programs.

## Ruby-style ergonomics

Specified in [`future.md` section 11](future.md#11-ruby-style-ergonomics). Agents write Ruby and Python habits (`docs/eval-diagnostics.md`); accept the Ruby forms that keep static checking and immutable values. One pull request per step, each stacked on the previous one and moving its part of section 11 into `grammar.md` and the programming reference.

- [x] Specify operators, methods on builtins, interpolation, blocks and closures, and hints in `future.md` section 11.
- [x] Operators: `!`, `&&`, `||`, and compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`).
- [x] Methods on builtin types with the Ruby aliases, and `CHECK-UNUSED-VALUE` for unused results of builtins without effects.
- [x] String interpolation with `#{...}` and the `\#` escape.
- [x] Blocks and closures: `do |x| ... end` as the last argument, capture by value, `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET`, `CHECK-CAPTURED-ASSIGNMENT`; closures accepted everywhere a `Fn` is (tasks, HTTP, BDD); `List.each`, `List.any?`, `List.all?`; `examples/blocks.agc`.
- [ ] Hints for foreign habits (`len`, `str`, `print`, `input`, `range`, `None`, `elif`, `to_i` used as `Int`).
- [ ] Teach the Ruby forms in the programming skill and examples; re-run the `binary` evaluation arm and `tests/eval/diagnostics.py`, and compare with the 2026-10-10 snapshot.

**Done when:** the Ruby forms check and run with the same diagnostics quality as the module forms, and the evaluation shows the effect.

## Phase 7: Bytecode VM

Replace the tree-walking evaluator with a bytecode VM written in C with the Boehm GC, step by step, without changing the language. The Racket front end (lexer, parser, module linker, checker) stays. It lowers the checked program to a typed intermediate form (IR), then to bytecode that the VM runs.

Why a VM and not a transpiler or LLVM IR: agents write, run and repair in a loop, so start-up time matters more than peak speed, and users should not need a compiler toolchain. A VM keeps `--max-steps`, the call-depth limit and located runtime diagnostics almost for free. Transpiling to C can come later from the same IR if native binaries are needed. Why C with Boehm: C is small, fast to build and available everywhere, and the VM can ship as one static binary. The Boehm GC removes manual memory management from the VM and runtime, so values can be shared freely without reference counting. The cost is that the runtime (tasks, files, processes, TLS, HTTP, JSON) must be written in C, so memory safety depends on discipline and tooling (sanitizers, fuzzing of the loader).

Rules for every subphase:

- The language does not change. `grammar.md` stays the contract; the Racket evaluator stays the reference until 7i.
- Same observable behavior: stdout, stderr, exit code, diagnostic code and span. Differential tests prove it.
- Diagnostic codes stay stable. The VM reports `RUNTIME-` diagnostics with the original source span.
- No placeholder files, directories or opcodes for later subphases.
- C naming: every exported function, type and global of the VM library uses the `agc_` prefix (`agc_value`, `agc_vm_run`); macros and enum constants use `AGC_` (`AGC_OP_ADD`). File-local helpers are `static`, so they need no prefix.

### 7a: Baseline measurements (merged into 7g)

The Racket evaluator stays in the repository until 7i, so it can be measured at any time. Profiling a Racket tree walker does not inform the design of a C VM. All measurement work therefore happens in 7g, when both backends run the same programs.

### 7b: Design decisions (`docs/vm.md`)

- [ ] IR: closures (block bodies with their captured values) from the Ruby-style ergonomics phase.
- [ ] IR: shape of the lowered program (functions, locals as slots, typed operations, explicit control flow, span per instruction).
- [ ] Bytecode: instruction set, constant pool, function table, struct/enum layouts, span table, format version.
- [ ] Serialization between Racket and the VM: binary or JSON, versioned, rejected on version mismatch.
- [ ] Value representation in C: tagged values allocated with the Boehm GC (`GC_MALLOC`, `GC_MALLOC_ATOMIC` for strings and numbers); Int (int64_t, checked with `__builtin_*_overflow`), Float (f64), Bool, Nil, Void, String (UTF-8 plus character indexing rules), List, Map (insertion order, structural sharing), struct, enum, Result, function value, Json, opaque handles.
- [ ] Execution limits: one step per instruction or per former AST entry; the reported step counts must match the evaluator or the difference must be documented.
- [ ] Call-depth limit (10000) and stack layout.
- [ ] How the CLI runs the VM: flag (`--vm`), a separate binary, or both; how `dist/` packages it.
- [ ] Dependency policy: C11, libc and the Boehm GC (`libgc`) for the core; static or dynamic linking of libgc; decide the TLS library (OpenSSL or another) and the event loop for tasks and I/O (poll/epoll by hand or libevent) before 7h. HTTP framing and JSON are written in C, following `http-wire.rkt` and `json.rkt`.
- [ ] Seeded `Random`: implement Racket's generator algorithm (MRG32k3a) in C so `--seed` gives the same sequence, or document that sequences are backend-specific.
- [ ] Build and CI: a `make vm` target with a C compiler and `libgc`; build with warnings as errors; run the VM tests next to `make test`; a sanitizer job (UBSan, and ASan where it works with Boehm) and a Valgrind or GC-debug run.

**Done when:** `docs/vm.md` answers each item above and the open decisions are closed.

### 7c: Lowering to IR (Racket)

- [ ] `src/lower.rkt`: checked program → IR. Resolve names to slots and indexes, make types explicit, keep spans.
- [ ] Lower every core form: literals, operators, `if`/`while`/`for`, functions, returns, structs, field access, lists, maps, indexing, enums and `case`, `Result`, `try`, `&name` and `.call`.
- [ ] `--dump-ir` in the CLI for debugging.
- [ ] `tests/lower-test.rkt`: one test per form, plus span checks.

**Done when:** every program in `examples/` lowers without error.

### 7d: Bytecode emitter

- [ ] `src/bytecode.rkt`: IR → bytecode plus constant pool and span table.
- [ ] Serialize to the format from 7b; `agentica compile file.agc -o file.agcb` writes it.
- [ ] Round-trip test: write, read back, compare.

**Done when:** every program in `examples/` compiles to a bytecode file.

### 7e: VM core (C + Boehm)

- [ ] Source layout under `vm/` (one module per area: loader, values, interpreter loop, builtins, diagnostics; public names prefixed `agc_`); `make vm` builds `dist/agentica-vm`; small C tests use plain `assert`, no framework.
- [ ] Loader with format-version check; it rejects truncated or malformed bytecode without crashing, and a fuzz run proves it.
- [ ] Values and checked Int arithmetic (`RUNTIME-INTEGER-OVERFLOW`, `RUNTIME-DIVISION-BY-ZERO`), IEEE Float comparisons as in the evaluator.
- [ ] Control flow, locals, function calls, returns, call-depth limit (`RUNTIME-STACK-OVERFLOW`), `--max-steps` (`RUNTIME-STEP-LIMIT`).
- [ ] Structs, lists, maps (insertion order), indexing errors with their spans.
- [ ] Enums, `case`, `Result`, `try`, function values.
- [ ] `IO` (stdin/stdout/stderr, bytes, flush, EOF), `System.args`, `System.exit`.
- [ ] `String`, `List`, `Map`, `Float`, `Time` and `Random` builtins.
- [ ] Runtime diagnostics printed in the plain, `--ai` and `--json` formats, identical to the evaluator.

**Done when:** every non-network, non-process, non-task example runs on the VM.

### 7f: Differential tests

- [ ] A harness that runs each program on the evaluator and on the VM and compares stdout, stderr, exit code and diagnostic code/span.
- [ ] Inputs: `examples/`, `tests/eval/tasks/*` (reference solutions and hidden cases), and a set of rejected-at-runtime programs.
- [ ] Run it in `make test` and CI; a missing VM build fails CI and visibly skips locally.

**Done when:** all core programs match on both backends.

### 7g: Speed check

- [ ] Add a benchmark script under `benchmarks/` (next to `maps.rkt`) that runs CPU-heavy programs with fixed inputs and reports wall time: `knight-tour`, `maze-bfs`, `traveling-salesman`, plus small loops for arithmetic, string building, list and map operations, function calls and `case`.
- [ ] Compare three runners on the same inputs: the Racket evaluator, the VM, and the Python reference solutions in `tests/eval/tasks/` as an outside reference.
- [ ] Measure start-up time separately (`hello.agc`) for `racket src/main.rkt`, `dist/agentica` and the VM.
- [ ] Record the numbers, machine and tool versions in `docs/vm-benchmarks.md`.
- [ ] Fix the largest VM hot spots (instruction dispatch, list/map representation, string indexing).

**Done when:** the numbers show whether the VM is worth finishing; decide here before 7h.

### 7h: Runtime services on the VM

- [ ] JSON: parse, extract, encode, builders, typed decode and schema.
- [ ] Files and paths.
- [ ] Lightweight tasks: scheduler, `Task.spawn/await/sleep`, shared step budget, cancellation on return.
- [ ] Processes, behind `--allow-run`.
- [ ] TCP and TLS.
- [ ] HTTP/1.1 clients and servers.
- [ ] Modules: `std/` and `pkg/` resolution stay in the front end; check that linked programs run.
- [ ] BDD: decide whether handlers keep using the Racket evaluator or move to the VM.
- [ ] Extend the differential tests and the independent network/process fixtures to the VM.

**Done when:** every example and every CI smoke test runs on the VM with the same results.

### 7i: Switch the default backend

- [ ] Make the VM the default for `agentica run`; keep the evaluator behind a flag for one release.
- [ ] Package the VM in `dist/` and the release workflow.
- [ ] Update `README.md`, the development skill and `CHANGELOG.md`.
- [ ] Decide whether to remove the Racket evaluator or keep it as the reference for differential tests.

**Done when:** a release ships with the VM as the default backend.

## Later extensions

- [x] Faster maps: replaced association lists in `src/evaluator.rkt` with Racket immutable equal?-based hashes plus reversed insertion-order keys; `mapping-put` remains the only writer. Lookup/update are effectively constant-time in map size (technically O(log n), excluding key hashing/comparison), Map.size is O(1), and Map.keys is O(n). Replacement preserves first-insertion order, old maps stay unchanged, and missing keys keep their diagnostic spans. Extended evaluator coverage for replacements, equal String keys, Int keys, false/nil payloads, empty maps, and nested debug order. `racket benchmarks/maps.rkt` compares checked build/build+read workloads at 1k/10k/50k entries (three-sample medians, no CI timing thresholds). Completed before JSON (5f). Lists retain O(n) indexing; favor `for`, with no runtime rewrite.
  Local benchmark on Racket CS 9.3: three-sample medians, baseline `27c8cd4` versus hash-backed maps. Timings include evaluation only; build+read includes construction followed by one membership check and indexed read per entry. These are observations, not CI limits or timing guarantees.

  | Entries | Build before / after (ms) | Build+read before / after (ms) |
  |---|---|---|
  | 1,000 | 9.94 / 1.23 | 25.11 / 2.85 |
  | 10,000 | 869.56 / 12.59 | 2,200.83 / 29.21 |
  | 50,000 | 23,240.65 / 61.62 | 54,904.19 / 146.60 |

### Enums and pattern matching: implemented

- [x] Specify generic enums, enum-qualified variants, and qualified imported names (`Domain.Option.Some`).
- [x] Implement Elixir-inspired `case expression do ... -> ... end` as a statement, with literal and variant patterns, direct bindings, `_` payload discards, and arm-local scopes.
- [x] Check generic constructor inference, enum and builtin Result exhaustiveness, wildcard requirements for non-enums, and unreachable arms.
- [x] Add parser, checker, evaluator, and module-linker regression tests; move normative syntax to `grammar.md` and mirror it in the programming reference and development skill.
- [ ] Define normative designs for interpolation, generics, methods, FFI, async, or actors before implementing them. Modules/imports have an explicit place in the current implementation order; error propagation is already implemented in 5e.
- [x] Complete lightweight I/O concurrency before networking in phase 5j2. Channels and CPU parallelism remain unscheduled; [`future.md` section 8](future.md#8-concurrency-and-parallelism) records their remaining decisions.

- [ ] No structural unions (`Int | String`): they need flow-sensitive narrowing and duplicate the exhaustiveness work of enums. Sum types come from enums. After Phase 6, decide whether agents need a builtin `Option[T]` (special-cased like `Result[T]`) for nullable values.

The remaining items above are outside the current implementation order.
