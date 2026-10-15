# Diagnostics

A failure prints to stderr and exits 1; the run stops at the first error:

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The prefix is the stage: `LEX-`, `PARSE-`, `CHECK-` (before running), `RUNTIME-` (while running). With `--json`, the diagnostic that ends the run is the last stderr line; the program's own stderr comes before it. Expected process failures return error Results. Codes without a row below: `CHECK-VOID-TYPE` and `CHECK-VOID-VALUE` (see `language.md`), and `RUNTIME-PROCESS-CLOSE` (a failed explicit process cleanup, at the call span).

A runtime error also prints the call stack of the task that failed, innermost first, in the plain, `--ai` and `--json` formats (no flag). It shows when the task has more than one frame or is not `main`; a failure directly in `main` has none:

```text
nested.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]
index 5 is outside a list of length 3

2 |   return xs[i] + 1
  |             ^
  = stack, innermost first:
    pick at nested.agc:2:13
    load at nested.agc:6:10
    main at nested.agc:11:8
```

Each line is a function and the place it runs: the error for the first, the call it waits on for the others. A block is `block`; the builtin that runs it (`xs.map`) has no line, so the caller's line is the `xs.map` call. `(after a tail call)` marks a frame whose callers a tail call (`return f(x)`) removed. `walk at tree.agc:9:12 (9998 times)` is one line for a recursion; after merging, only the 15 innermost and the 5 outermost lines show, with `... 312 frames not shown ...` between. A task ends with `task spawned at file:line:column`, the `Task.spawn` call. A function name or file path longer than 256 bytes is cut there, at a character boundary, and ends with `...`. `--ai` has the same lines under `  stack:`. `--json` adds `stack` (objects with `column`, `file`, `function`, `line`, and `repeat` or `tail` when they apply), `stack_omitted` and, for a task, `spawned_at`. `RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` have the stack too, and so does a task's crash line (`"task":true`).

| Code | Meaning |
|---|---|
| `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER` | bad character, string, or bracket. A `;` says Agentica has no semicolons (end the statement with a newline). A `'` or a backtick says strings use double quotes (a character is a one-character String). A `}` with no `{` open, and an unclosed `{`, say blocks end with `end`, not `}`. |
| `LEX-INVALID-NUMBER` | a `_` in a number literal that is not between two digits: `1_`, `1__0`, `1_.5`, `1._5`. Write `1_000` or `0.000_5`; the `_` is only visual |
| `PARSE-UNEXPECTED-TOKEN` | the parser expected something else here. A `{` after `def ... -> T`, `if`, `elsif`, `else`, `while`, `for`, `case` or `do |x|` says blocks have no braces and names the form: `while cond` ... `end`. A `//` or `/*` says comments start with `#` |
| `PARSE-UNCLOSED-BLOCK` | missing `end` |
| `PARSE-MISSING-BLANK-LINE` | no blank line between the `end` of a declaration and the next one; a `##` doc block counts as part of the next declaration, so the blank line goes before it |
| `PARSE-DETACHED-DOC` | a `##` doc block that is not directly above a `def`, `struct`, `enum`, field or variant: a blank line, a `#` comment, an `import` or the end of the file follows it, or it stands in a function body or inside brackets. Move it onto the line above what it documents, or write `#`. Only the first block of a file, followed by a blank line, may stand alone (the module doc) |
| `PARSE-TOP-LEVEL-STATEMENT` | a statement outside a function (put it in `def main() -> Void`), or an extra `end` (a stray `else` or `elsif` has no matching `if`) |
| `PARSE-CHAINED-COMPARISON` | `a < b < c` |
| `PARSE-INVALID-ASSIGNMENT-TARGET` | assignment to an index or field |
| `PARSE-PIPE-TARGET` | the right side of `\|>` is not a call written with parentheses (a bare name, field, index, `f(1).g`, `(U.f)`, `U.f do ... end`); wrap the pipe in parentheses and use `.` on the result. The call may follow `try` and take a trailing block. `a + 1 \|> f()` is `f(a + 1)`; put a multi-line chain in parentheses, one `\|>` per line |
| `CHECK-TYPE-MISMATCH` | a value, operand, condition, argument, or return has the wrong type; also printing or interpolating a value without `to_s` (a function, task or handle). Int with Float: `n.to_f`, `x.to_i!`; String with a number: `s.to_i!`, `n.to_s`; `<` on Strings: only numbers are ordered |
| `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD` | a name, type, or field that does not exist (`continue` says `next`; `Map.new` says `m: Map[String, Int] = {}`) |
| `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING` | duplicate declaration, shadowing, annotation on an existing name |
| `CHECK-ARITY` | wrong number of arguments |
| `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD` | struct construction fields |
| `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE` | an empty `[]` or `{}`, respectively, with no expected type: annotate it, `m: Map[String, Int] = {}` |
| `CHECK-RESULT-TYPE` | an error constructor without an expected Result type |
| `CHECK-EXPECTED-TYPE` | `Channel.new(n)` with no expected type; annotate it: `ch: Channel[Int] = Channel.new(8)` (see `tasks.md`) |
| `CHECK-TRY-CONTEXT` | try in a function not returning Result |
| `CHECK-MISSING-RETURN` | a path without `return` in a non-`Void` function; the help names the missing `else`, loop or `case` arm |
| `CHECK-MAIN` | missing or wrong `main` |
| `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST` | index on a non-list/map (a String uses `s.at(i)` or `s.slice(start, length)`), `for` over something that is not a list or a range |
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
| `CHECK-UNKNOWN-METHOD` | method not defined for the receiver's type, or a method call on a struct. Common foreign names get the real one: `s.chars` says `s.split("")`, `s.matches?` says `contains?`, `to_string` says `to_s` |
| `CHECK-UNUSED-VALUE` | result of a builtin without effects is ignored (`xs.push(1)` alone) |
| `CHECK-BLOCK-TYPE` | a block parameter has no type from the call; annotate it (`do |x: Int|`) |
| `CHECK-BLOCK-TARGET` | a block is passed to a function whose last parameter is not a `Fn` |
| `CHECK-LOOP-CONTROL` | `break` or `next` outside a `while`/`for` body, or inside a block |
| `CHECK-CAPTURED-ASSIGNMENT` | a block assigns to an outer variable; use a `for` loop or `reduce`. For `xs.each do |w|` on a name or field the help shows the loop, `for w in xs ... end`, which can assign the variable |
| `CHECK-NOT-A-HANDLE` | `Task.spawn_owning` with an argument that is not a `FileHandle`, `Socket`, `Listener`, `Process`, `HttpServer` or `Channel[T]`, at the argument (see `tasks.md`) |
| `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW` | arithmetic failure |
| `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND` | list index or map key not present |
| `RUNTIME-INVALID-COUNT` | List.repeat count outside 0..1048576, or negative List.take/drop count; `Channel.new` capacity outside 1..1048576; a negative `Int.shift_left`/`shift_right`/`shift_right_unsigned` count |
| `RUNTIME-INVALID-NUMBER` | `String.to_int!` / `String.to_float!` on bad text, `Float.to_int!` on NaN or infinity, `Float.from_bits32` outside 0..4294967295 |
| `RUNTIME-INVALID-RANGE` | `Random.int` with `min > max` |
| `RUNTIME-INVALID-CHARACTER` | `String.code` without exactly one character, or `String.from_code` outside Unicode scalar values |
| `RUNTIME-END-OF-INPUT` | `IO.gets!` with no input left |
| `RUNTIME-UNWRAP-ERROR` | Result.unwrap! on an error |
| `RUNTIME-JSON-ENCODE` | JSON.encode cannot represent a non-finite Float |
| `RUNTIME-STEP-LIMIT` | execution step budget exhausted; the stack shows where the loop runs |
| `RUNTIME-STACK-OVERFLOW` | recursion too deep (depth 10000); the stack shows the repeating function once, with its count; only `return f(...)` tail calls are free, so rewrite with an accumulator or a loop |
| `RUNTIME-INVALID-DURATION` | negative `Task.sleep` duration, negative `Channel.send`/`Channel.recv` timeout, or a `Task.await(task, timeout_ms)` timeout of 0 or less (see `tasks.md`) |
| `RUNTIME-TASK-CANCELLED` | `Task.await` on a task the VM cancelled when `R` is not a `Result`, at the await (see `tasks.md`); a task can hold a cancelled child's handle by receiving it over a channel |
| `RUNTIME-TASK-AWAIT-CYCLE` | `Task.await` of a task that is waiting for the caller, directly or through other awaits, at the await (see `tasks.md`) |
| `RUNTIME-HANDLE-NOT-OWNED` | `Task.spawn_owning` of a handle the calling task does not own, one already handed over, or a closed one (a closed channel too), at the handle argument (see `tasks.md`) |
| `RUNTIME-TASK-CRASHED` | `Task.await` on a crashed task when `R` is not a `Result`, at the await; the message is the crash text (see `tasks.md`); a BDD step or a test whose task crashed unawaited |
| `RUNTIME-TEST-ASSERTION` | a failed `Test.eq`, `Test.ok?`, `Test.error?` or `Test.assert` in a test, at the assertion (see `testing.md`) |
| `RUNTIME-TEST-ERROR` | a test block returned `error(message)`, at the `Test.test` call |
| `RUNTIME-TEST-NAME` | an empty or repeated test name, at that `Test.test` call |
| `RUNTIME-TEST-RUN` | `Test.run` called in a task other than `main`'s own (a test, or a task you spawned); call it from `main` itself. It is also the code of a call with the `agentica test` arguments but no parent channel. Under `agentica test` it also names a test file whose `main` returns without calling `Test.run` (a `*_test.agc` helper: rename it) |
| `RUNTIME-TEST-PENDING-TASKS` | a test returned while tasks it spawned were still running; await them |
| `RUNTIME-TEST-TIMEOUT` | under `agentica test`, a test ran longer than 30 seconds; the rest of its file is not executed |
| `LOWER-UNSUPPORTED` | the VM cannot run this form; exit 1 before anything runs. Every checked program runs on the VM today, so seeing it is an interpreter bug to report |

BDD runs (`agentica test`) have their own `PARSE-GHERKIN-*`, `CHECK-BDD-*` and `RUNTIME-BDD-*` codes; see `bdd.md`.
