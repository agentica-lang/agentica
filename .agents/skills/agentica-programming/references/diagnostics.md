# Diagnostics

A failure prints to stderr and exits 1; the run stops at the first error:

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The prefix is the stage: `LEX-`, `PARSE-`, `CHECK-` (before running), `RUNTIME-`
(while running). With `--json`, the diagnostic that ends the run is the last
stderr line; the program's own stderr comes before it. Expected process failures
return error Results. Codes without a row below: `CHECK-VOID-TYPE` and
`CHECK-VOID-VALUE` (see `language.md`), and `RUNTIME-PROCESS-CLOSE` (a failed
explicit process cleanup, at the call span).

A runtime error also prints the call stack of the task that failed, innermost
first, in the plain, `--ai` and `--json` formats (no flag). It shows when the
task has more than one frame or is not `main`; a failure directly in `main` has
none:

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

A runtime trace names each file as you can open it from the working directory
(`agentica examples/hello.agc` shows `examples/hello.agc:3:5` and
`examples/lib/util.agc:7:11`), and a standard module as `std/NAME.agc`;
compile-time errors show the first file as typed and an imported file by
absolute path. Each line is a function and the place it runs: the error for the
first, the call it waits on for the others. A block is `block`; the builtin that
runs it (`xs.map`) has no line, so the caller's line is the `xs.map` call.
`(after a tail call)` marks a frame whose callers a tail call (`return f(x)`)
removed. `walk at tree.agc:9:12 (9998 times)` is one line for a recursion; after
merging, only the 15 innermost and the 5 outermost lines show, with `... 312
frames not shown ...` between. A task ends with `task spawned at
file:line:column`, the `Task.spawn` call. A function name or file path longer
than 256 bytes is cut there, at a character boundary, and ends with `...`.
`--ai` has the same lines under `  stack:`. `--json` adds `stack` (objects with
`column`, `file`, `function`, `line`, and `repeat` or `tail` when they apply),
`stack_omitted` and, for a task, `spawned_at`. `RUNTIME-STEP-LIMIT` and
`RUNTIME-STACK-OVERFLOW` have the stack too, and so does a task's crash line
(`"task":true`).

- **Code:** `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`,
  `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`
  - **Meaning:** bad character, string, or bracket. A `;` says Agentica has no
    semicolons (end the statement with a newline). A `'` or a backtick says
    strings use double quotes (a character is a one-character String). A `}`
    with no `{` open, and an unclosed `{`, say blocks end with `end`, not `}`.

- **Code:** `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`,
  `LEX-HEREDOC-ONE-LINE`
  - **Meaning:** a heredoc `<<~NAME` with no end line (a line with only `NAME`;
    the span is the opener), a tab in the leading whitespace of a body line or
    of the end line (indent with spaces; the span is the tab), or a heredoc with
    fewer than two lines of text (write `"text\n"`). `<<NAME`, `<<-NAME`,
    `<<~'NAME'` and `<<~name` are `LEX-UNEXPECTED-CHAR` with a help that shows
    `<<~NAME`; `xs << x` is `PARSE-UNEXPECTED-TOKEN` with a help that shows `xs
    = xs.push(x)`

- **Code:** `LEX-INVALID-UTF8`
  - **Meaning:** a source file (the one you run or one it imports) holds bytes
    that are not valid UTF-8. The span is the first bad byte; save the file as
    UTF-8

- **Code:** `LEX-INVALID-NUMBER`
  - **Meaning:** a `_` in a number literal that is not between two digits: `1_`,
    `1__0`, `1_.5`, `1._5`. Write `1_000` or `0.000_5`; the `_` is only visual

- **Code:** `PARSE-UNEXPECTED-TOKEN`
  - **Meaning:** the parser expected something else here. A `{` after `def ...
    -> T`, `if`, `elsif`, `else`, `while`, `for`, `case` or `do |x|` says blocks
    have no braces and names the form: `while cond` ... `end`. A `//` or `/*`
    says comments start with `#`. `value.with()` and `value.with(31)` say to
    name each field to change, as in `value.with(age: 31)`

- **Code:** `PARSE-UNCLOSED-BLOCK`
  - **Meaning:** missing `end`

- **Code:** `PARSE-MISSING-BLANK-LINE`
  - **Meaning:** no blank line between the `end` of a declaration and the next
    one; a `##` doc block counts as part of the next declaration, so the blank
    line goes before it

- **Code:** `PARSE-DETACHED-DOC`
  - **Meaning:** a `##` doc block that is not directly above a `def`, `struct`,
    `enum`, field or variant: a blank line, a `#` comment, an `import` or the
    end of the file follows it, or it stands in a function body or inside
    brackets. Move it onto the line above what it documents, or write `#`. Only
    the first block of a file, followed by a blank line, may stand alone (the
    module doc)

- **Code:** `PARSE-TOP-LEVEL-STATEMENT`
  - **Meaning:** a statement outside a function (put it in `def main() ->
    Void`), or an extra `end` (a stray `else` or `elsif` has no matching `if`)

- **Code:** `PARSE-CHAINED-COMPARISON`
  - **Meaning:** `a < b < c`

- **Code:** `PARSE-TOO-DEEP`
  - **Meaning:** more than 1,000 levels of nesting (parentheses, brackets,
    blocks, statements, prefix operators, type arguments), or chains of
    operators or `.` suffixes counted as levels too (what follows the k-th link
    of a chain is k levels deeper); split the code into functions or bindings

- **Code:** `PARSE-INVALID-ASSIGNMENT-TARGET`
  - **Meaning:** assignment to an index or field, or to a constant inside a
    function (constants never change)

- **Code:** `PARSE-CONSTANT-NAME`
  - **Meaning:** a top-level `Name = ...` whose name is not capitals, digits and
    `_` of two or more characters; the help gives `MAX_DEPTH` for `MaxDepth`

- **Code:** `PARSE-PIPE-TARGET`
  - **Meaning:** the right side of `\|>` is not a call written with parentheses
    (a bare name, field, index, `f(1).g`, `(U.f)`, `U.f do ... end`); wrap the
    pipe in parentheses and use `.` on the result. The call may follow `try` and
    take a trailing block. `a + 1 \|> f()` is `f(a + 1)`; put a multi-line chain
    in parentheses, one `\|>` per line

- **Code:** `CHECK-TYPE-MISMATCH`
  - **Meaning:** a value, operand, condition, argument, or return has the wrong
    type; also printing or interpolating a value without `to_s` (a function,
    task or handle). Int with Float: `n.to_f`, `x.to_i!`; String with a number:
    `s.to_i!`, `n.to_s`; `<` on Strings: only numbers are ordered

- **Code:** `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD`
  - **Meaning:** a name, type, or field that does not exist (`continue` says
    `next`; `Map.new` says `m: Map[String, Int] = {}`); also a field that
    `value.with(...)` names but the struct lacks

- **Code:** `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`,
  `CHECK-ANNOTATION-ON-EXISTING`
  - **Meaning:** duplicate declaration, shadowing, annotation on an existing
    name; an `Fn` field named `with` (`value.with(...)` is the struct update, so
    rename the field)

- **Code:** `CHECK-ARITY`
  - **Meaning:** wrong number of arguments; for a function with default values
    the message gives the range (`expects 1 to 2 arguments`)

- **Code:** `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`
  - **Meaning:** a parameter without a default after one with a default (only a
    last `Fn` parameter may stay without one); a default that is not a constant
    (a literal, `true`, `false`, `nil`, `[]`, `{}` or an enum variant without a
    payload): make the parameter required instead

- **Code:** `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD`
  - **Meaning:** struct construction fields

- **Code:** `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`
  - **Meaning:** an empty `[]` or `{}`, respectively, with no expected type:
    annotate it, `m: Map[String, Int] = {}`

- **Code:** `CHECK-RESULT-TYPE`
  - **Meaning:** an error constructor without an expected Result type

- **Code:** `CHECK-EXPECTED-TYPE`
  - **Meaning:** `Channel.new(n)` with no expected type; annotate it: `ch:
    Channel[Int] = Channel.new(8)` (see `tasks.md`)

- **Code:** `CHECK-TRY-CONTEXT`
  - **Meaning:** try in a function or block not returning Result (a block of
    a `Lazy` method accepts any `try`: its failure ends the pipeline)

- **Code:** `CHECK-MISSING-RETURN`
  - **Meaning:** a path without `return` in a non-`Void` function; the help
    names the missing `else`, loop or `case` arm

- **Code:** `CHECK-MAIN`
  - **Meaning:** missing or wrong `main`

- **Code:** `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST`
  - **Meaning:** index on a non-list/map (a String uses `s.at(i)` or
    `s.slice(start, length)`), `for` over something that is not a list, a set or
    a range

- **Code:** `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`,
  `CHECK-ENUM-TYPE-INFERENCE`
  - **Meaning:** unknown enum variant, named arguments to a variant, generic
    enum type not known from payloads or context

- **Code:** `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`,
  `CHECK-UNREACHABLE-CASE-ARM`
  - **Meaning:** a pattern that does not fit the value, a `case` missing
    variants or `_`, an arm already covered

- **Code:** `CHECK-MAP-KEY-TYPE`
  - **Meaning:** a map key that is not `Int` or `String`

- **Code:** `CHECK-SET-ELEMENT-TYPE`, `CHECK-EMPTY-SET-TYPE`
  - **Meaning:** a `Set` element type that is not `Int` or `String`;
    `Set.new([])` with no expected type: annotate it, `s: Set[Int] =
    Set.new([])`

- **Code:** `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`,
  `CHECK-IMPORT-NAME`
  - **Meaning:** Missing/unreadable import, invalid path (including a path with
    `.agc` or another extension), cycle, or unknown/private imported name; for a
    misspelled name the help suggests the closest export (`did you mean
    "name"?`); a struct that its module keeps private cannot be constructed or
    updated with `.with` from another module; `Mod.NAME` on a constant is also
    `CHECK-IMPORT-NAME` (write `import {NAME} from "path"`)

- **Code:** `CHECK-IMPORT-RENAME`
  - **Meaning:** `import {A as b}` where the new name breaks the case rule of
    what it renames: a struct or enum gets a capitalized name, a function a
    lowercase one, a constant a constant name (capitals and underscores)

- **Code:** `CHECK-CONSTANT-EXPRESSION`
  - **Meaning:** a constant uses a call of your own function, `&f`, a block
    outside a builtin call, `while`, or a builtin with effects; compute it in a
    function instead

- **Code:** `CHECK-CONSTANT-TYPE`
  - **Meaning:** a constant expression has a type that is not data (`Channel`,
    `Task`, `Fn`, handles, `Void`)

- **Code:** `CHECK-CONSTANT-CYCLE`
  - **Meaning:** constants that read each other in a loop; the help lists `A ->
    B -> A`

- **Code:** `CHECK-DECL-ORDER`
  - **Meaning:** a declaration out of the file order (imports, constants,
    `struct`/`enum`/type aliases, `export def`, `def`): a type after a function,
    a private `def` before an `export def`, an `import` after a declaration;
    move it to its group

- **Code:** `CHECK-MODULE-CONTEXT`
  - **Meaning:** Raw import/export declarations need module resolution before
    checking

- **Code:** `CHECK-NOT-DECODABLE`
  - **Meaning:** JSON.decode/schema target is not a struct or contains
    unsupported field types

- **Code:** `CHECK-NOT-ENCODABLE`
  - **Meaning:** JSON.encode on a type with unsupported nested values or
    Int-keyed maps

- **Code:** `CHECK-IMMUTABLE-ASSIGNMENT`
  - **Meaning:** assignment to a `for` variable

- **Code:** `CHECK-INT-RANGE`
  - **Meaning:** an integer literal that does not fit in `Int`

- **Code:** `CHECK-PIPE-METHOD`
  - **Meaning:** `x \|> String.trim()`: a builtin that has a method form for the
    left value is written with `.` (`x.trim`); the help shows the method form,
    with a piped left side in parentheses

- **Code:** `CHECK-UNKNOWN-METHOD`
  - **Meaning:** method not defined for the receiver's type, or a method call on
    a struct, or `.with(...)` on a value that is not a struct. Common foreign
    names get the real one: `s.chars` says `s.split("")`, `s.matches?` says
    `contains?`, `to_string` says `to_s`

- **Code:** `CHECK-LAZY-NO-STEP`
  - **Meaning:** `File.foreach(...).each do ... end` with no step in between,
    written as one chain;
    write `File.each_line(path, n, ms) do |line| ... end`

- **Code:** `CHECK-UNUSED-VALUE`
  - **Meaning:** result of a builtin without effects is ignored (`xs.push(1)`
    alone), or of a struct update (`user.with(age: 31)` alone)

- **Code:** `CHECK-BLOCK-TYPE`
  - **Meaning:** a block parameter has no type from the call; annotate it (`do
    |x: Int|`)

- **Code:** `CHECK-BLOCK-TARGET`
  - **Meaning:** a block is passed to a function whose last parameter is not a
    `Fn`

- **Code:** `CHECK-LOOP-CONTROL`
  - **Meaning:** `break` or `next` outside a `while`/`for` body, or inside a
    block

- **Code:** `CHECK-CAPTURED-ASSIGNMENT`
  - **Meaning:** a block assigns to an outer variable; use a `for` loop or
    `reduce`. For `xs.each do |w|` on a name or field the help shows the loop,
    `for w in xs ... end`, which can assign the variable

- **Code:** `CHECK-NOT-A-HANDLE`
  - **Meaning:** `Task.spawn_owning` with an argument that is not a
    `FileHandle`, `Socket`, `Listener`, `Process`, `HttpServer` or `Channel[T]`,
    at the argument (see `tasks.md`)

- **Code:** `CHECK-TYPE-ALIAS-CYCLE`
  - **Meaning:** a type alias that expands to itself, directly or through other
    aliases; break the cycle

- **Code:** `CHECK-TOO-DEEP`
  - **Meaning:** more than 1,000 levels of expressions and statements, or more
    than 1,000 type references in an expanded alias; split the code or aliases
    into smaller parts

- **Code:** `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`
  - **Meaning:** arithmetic failure

- **Code:** `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND`
  - **Meaning:** list index or map key not present

- **Code:** `RUNTIME-INVALID-COUNT`
  - **Meaning:** List.repeat count outside 0..1048576, or negative
    List.take/drop count; `Channel.new` capacity outside 1..1048576; a
    `Task.map` `limit` outside 1..1024; a negative
    `Int.shift_left`/`shift_right`/`shift_right_unsigned` count

- **Code:** `RUNTIME-INVALID-NUMBER`
  - **Meaning:** `String.to_int!` / `String.to_float!` on bad text,
    `Float.to_int!` on NaN or infinity, `Float.from_bits32` outside
    0..4294967295

- **Code:** `RUNTIME-INVALID-RANGE`
  - **Meaning:** `Random.int` with `min > max`

- **Code:** `RUNTIME-INVALID-CHARACTER`
  - **Meaning:** `String.code` without exactly one character, or
    `String.from_code` outside Unicode scalar values

- **Code:** `RUNTIME-END-OF-INPUT`
  - **Meaning:** `IO.gets!` with no input left

- **Code:** `RUNTIME-UNWRAP-ERROR`
  - **Meaning:** Result.unwrap! on an error

- **Code:** `RUNTIME-JSON-ENCODE`
  - **Meaning:** JSON.encode cannot represent a non-finite Float

- **Code:** `RUNTIME-STEP-LIMIT`
  - **Meaning:** execution step budget exhausted; the stack shows where the loop
    runs

- **Code:** `RUNTIME-STACK-OVERFLOW`
  - **Meaning:** recursion too deep (depth 10000); the stack shows the repeating
    function once, with its count; only `return f(...)` tail calls are free, so
    rewrite with an accumulator or a loop

- **Code:** `RUNTIME-INVALID-DURATION`
  - **Meaning:** negative `Task.sleep` duration, negative
    `Channel.send`/`Channel.recv` timeout, a `Task.await(task, timeout_ms)`
    timeout of 0 or less, or a `Task.map` `timeout_ms` of 0 or less (see
    `tasks.md`)

- **Code:** `RUNTIME-TASK-CANCELLED`
  - **Meaning:** `Task.await` on a task the VM cancelled when `R` is not a
    `Result`, at the await (see `tasks.md`); a task can hold a cancelled child's
    handle by receiving it over a channel, for example from a `Task.map` item
    that timed out

- **Code:** `RUNTIME-TASK-AWAIT-CYCLE`
  - **Meaning:** `Task.await` of a task that is waiting for the caller, directly
    or through other awaits, at the await (see `tasks.md`)

- **Code:** `RUNTIME-HANDLE-NOT-OWNED`
  - **Meaning:** `Task.spawn_owning` of a handle the calling task does not own,
    one already handed over, or a closed one (a closed channel too), at the
    handle argument (see `tasks.md`)

- **Code:** `RUNTIME-TASK-CRASHED`
  - **Meaning:** `Task.await` on a crashed task when `R` is not a `Result`, at
    the await; the message is the crash text (see `tasks.md`); a BDD step or a
    test whose task crashed unawaited

- **Code:** `RUNTIME-TEST-ASSERTION`
  - **Meaning:** a failed `Test.eq`, `Test.ok?`, `Test.error?` or `Test.assert`
    in a test, at the assertion (see `testing.md`)

- **Code:** `RUNTIME-TEST-ERROR`
  - **Meaning:** a test block returned `error(message)`, at the `Test.test` call

- **Code:** `RUNTIME-TEST-NAME`
  - **Meaning:** an empty or repeated test name, at that `Test.test` call

- **Code:** `RUNTIME-TEST-RUN`
  - **Meaning:** `Test.run` called in a task other than `main`'s own (a test, or
    a task you spawned); call it from `main` itself. It is also the code of a
    call with the `agentica test` arguments but no parent channel. Under
    `agentica test` it also names a test file whose `main` returns without
    calling `Test.run` (a `*_test.agc` helper: rename it)

- **Code:** `RUNTIME-TEST-PENDING-TASKS`
  - **Meaning:** a test returned while tasks it spawned were still running;
    await them

- **Code:** `RUNTIME-TEST-TIMEOUT`
  - **Meaning:** under `agentica test`, a test ran longer than 30 seconds; the
    rest of its file is not executed

- **Code:** `LOWER-UNSUPPORTED`
  - **Meaning:** the VM cannot run this form; exit 1 before anything runs. Every
    checked program runs on the VM today, so seeing it is an interpreter bug to
    report

BDD runs (`agentica test`) have their own `PARSE-GHERKIN-*`, `CHECK-BDD-*` and
`RUNTIME-BDD-*` codes; see `bdd.md`.
