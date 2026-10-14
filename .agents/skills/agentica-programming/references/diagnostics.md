# Diagnostics

`CHECK-VOID-TYPE` rejects Void in a data type position; `CHECK-VOID-VALUE` rejects using completion as data. A failed explicit cleanup of a process is `RUNTIME-PROCESS-CLOSE` at the call span. Expected process failures return error Results.

A failure prints to stderr and exits 1 (the run stops at the first error):

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The code prefix is the stage: `LEX-` (characters), `PARSE-` (syntax), `CHECK-` (names and types, before running), `RUNTIME-` (while running).

| Code | Meaning |
|---|---|
| `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER` | bad character, string, or bracket |
| `PARSE-UNEXPECTED-TOKEN` | the parser expected something else here |
| `PARSE-UNCLOSED-BLOCK` | missing `end` |
| `PARSE-MISSING-BLANK-LINE` | no blank line between the `end` of a declaration and the next one |
| `PARSE-TOP-LEVEL-STATEMENT` | a statement outside a function |
| `PARSE-CHAINED-COMPARISON` | `a < b < c` |
| `PARSE-INVALID-ASSIGNMENT-TARGET` | assignment to an index or field |
| `PARSE-PIPE-TARGET` | the right side of `\|>` is not a call written with parentheses (a bare name, field, index, `f(1).g`, `(U.f)`, `U.f do ... end`); wrap the pipe in parentheses and use `.` on the result. The call may follow `try` and take a trailing block. `a + 1 \|> f()` is `f(a + 1)`; put a multi-line chain in parentheses, one `\|>` per line |
| `CHECK-TYPE-MISMATCH` | a value, operand, condition, argument, or return has the wrong type; also printing or interpolating a value without `to_s` (a function, task or handle) |
| `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD` | a name, type, or field that does not exist |
| `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING` | duplicate declaration, shadowing, annotation on an existing name |
| `CHECK-ARITY` | wrong number of arguments |
| `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD` | struct construction fields |
| `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE` | an empty `[]` or `{}`, respectively, with no expected type |
| `CHECK-RESULT-TYPE` | an error constructor without an expected Result type |
| `CHECK-TRY-CONTEXT` | try in a function not returning Result |
| `CHECK-MISSING-RETURN` | a path without `return` in a non-`Void` function |
| `CHECK-MAIN` | missing or wrong `main` |
| `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST` | index on a non-list/map, `for` over something that is not a list or a range |
| `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`, `CHECK-ENUM-TYPE-INFERENCE` | unknown enum variant, named arguments to a variant, generic enum type not known from payloads or context |
| `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`, `CHECK-UNREACHABLE-CASE-ARM` | a pattern that does not fit the value, a `case` missing variants or `_`, an arm already covered |
| `CHECK-MAP-KEY-TYPE` | a map key that is not `Int` or `String` |
| `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`, `CHECK-IMPORT-NAME` | Missing/unreadable import, invalid path (including a path with `.agc` or another extension), cycle, or unknown/private imported name |
| `CHECK-MODULE-CONTEXT` | Raw import/export declarations need module resolution before checking |
| `CHECK-NOT-DECODABLE` | JSON.decode/schema target is not a struct or contains unsupported field types |
| `CHECK-NOT-ENCODABLE` | JSON.encode on a type with unsupported nested values or Int-keyed maps |
| `CHECK-IMMUTABLE-ASSIGNMENT` | assignment to a `for` variable |
| `CHECK-INT-RANGE` | an integer literal that does not fit in `Int` |
| `CHECK-PIPE-METHOD` | `x \|> String.trim()`: a builtin that has a method form for the left value is written with `.` (`x.trim`); the help shows the method form, with a piped left side in parentheses |
| `CHECK-UNKNOWN-METHOD` | method not defined for the receiver's type, or a method call on a struct |
| `CHECK-UNUSED-VALUE` | result of a builtin without effects is ignored (`xs.push(1)` alone) |
| `CHECK-BLOCK-TYPE` | a block parameter has no type from the call; annotate it (`do |x: Int|`) |
| `CHECK-BLOCK-TARGET` | a block is passed to a function whose last parameter is not a `Fn` |
| `CHECK-LOOP-CONTROL` | `break` or `next` outside a `while`/`for` body, or inside a block |
| `CHECK-CAPTURED-ASSIGNMENT` | a block assigns to an outer variable; use `reduce` or a `for` loop |
| `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW` | arithmetic failure |
| `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND` | list index or map key not present |
| `RUNTIME-INVALID-COUNT` | List.repeat count outside 0..1048576, or negative List.take/drop count |
| `RUNTIME-INVALID-NUMBER` | `String.to_int!` / `String.to_float!` on bad text, `Float.to_int!` on NaN or infinity |
| `RUNTIME-INVALID-RANGE` | `Random.int` with `min > max` |
| `RUNTIME-INVALID-CHARACTER` | `String.code` without exactly one character, or `String.from_code` outside Unicode scalar values |
| `RUNTIME-END-OF-INPUT` | `IO.gets!` with no input left |
| `RUNTIME-UNWRAP-ERROR` | Result.unwrap! on an error |
| `RUNTIME-JSON-ENCODE` | JSON.encode cannot represent a non-finite Float |
| `RUNTIME-STEP-LIMIT` | execution step budget exhausted |
| `RUNTIME-STACK-OVERFLOW` | recursion too deep |
| `RUNTIME-INVALID-DURATION` | negative `Task.sleep` duration (see `tasks.md`) |
| `RUNTIME-TASK-CANCELLED` | `Task.await` on a task the VM cancelled when `R` is not a `Result`, at the await (see `tasks.md`); no program can reach it yet (17a and 20c will) |
| `RUNTIME-TASK-CRASHED` | `Task.await` on a crashed task when `R` is not a `Result`, at the await; the message is the crash text (see `tasks.md`); a BDD step or a test whose task crashed unawaited |
| `RUNTIME-TEST-ASSERTION` | a failed `Test.eq`, `Test.ok?`, `Test.error?` or `Test.assert` in a test, at the assertion (see `testing.md`) |
| `RUNTIME-TEST-ERROR` | a test block returned `error(message)`, at the `Test.test` call |
| `RUNTIME-TEST-NAME` | an empty or repeated test name, at that `Test.test` call |
| `RUNTIME-TEST-RUN` | `Test.run` called in a task other than `main`'s own (a test, or a task you spawned); call it once, from `main`. Under `agentica test` it also names a test file whose `main` returns without calling `Test.run` (a `*_test.agc` helper: rename it) |
| `RUNTIME-TEST-PENDING-TASKS` | a test returned while tasks it spawned were still running; await them |
| `RUNTIME-TEST-TIMEOUT` | under `agentica test`, a test ran longer than 30 seconds; the rest of its file is not executed |
| `LOWER-UNSUPPORTED` | the VM cannot run this form; exit 1 before anything runs. Every checked program runs on the VM today, so seeing it is an interpreter bug to report |

BDD runs (`agentica test`) have their own `PARSE-GHERKIN-*`, `CHECK-BDD-*` and `RUNTIME-BDD-*` codes; see `bdd.md`.
