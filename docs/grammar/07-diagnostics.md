## 7. Diagnostics for agents

Each error has a stable code, a file, a line and a column, a concrete
explanation, and the source line with a mark under the span. Spans travel from
the tokens to the AST.

```text
example.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

When the checker knows the fix, the diagnostic ends with a `= help:` line.

A compile-time diagnostic names the first file as you typed it and an imported
file by its absolute path. A runtime diagnostic and the frames of its stack name
each file as you can open it from the working directory: `agentica
examples/hello.agc` reports `examples/hello.agc:3:5` and
`examples/lib/util.agc:7:11`, and a standard module is `std/NAME.agc`. The
bytecode stores each file relative to the folder of the first file (`hello.agc`,
`lib/util.agc`, `../shared/x.agc`), so it is the same wherever the program was
built; `agentica` puts the folder you typed before those names, and `agentica
run` alone prints them as stored.

`agentica --ai` and `agentica --json` print the same diagnostic as compact text,
or as one JSON object. In `--json` mode, when a diagnostic ends the run, it is
the last line of stderr, except that a warning about the flush of files or
output (§6) can follow it when the end-of-run flush fails or runs out of time.
Task crash lines (with `"task": true`), the unobserved-crash summary
(`{"unobserved_crashes": N, "first": "..."}`) and the flush warning of §6 are
not the run's diagnostic.

A runtime diagnostic of a running task also shows the call stack of the task
that failed, innermost frame first, in all three formats. There is no flag. The
stack is shown when the failing task has more than one frame or is not `main`; a
failure directly in `main` looks as it does without a stack.

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

A frame line is the function's declared name and the place it was running. For
the innermost frame that is the place of the error, and for each caller it is
the call it waits on. A block shows as `block`, a function from an imported file
shows its name (the file is in the place), and the builtins that run a block
(`xs.map`) are skipped, since the frame below already points at the call. A
frame that a tail call replaced is gone: the frame left ends with `(after a tail
call)`, so a reader knows that callers are missing there. Neighbouring frames
with the same function and place are one line with a count, as in `walk at
tree.agc:9:12 (9998 times)`, so a runaway recursion that ends in
`RUNTIME-STACK-OVERFLOW` takes a few lines. After that merge at most 20 lines
show: the 15 innermost, a line `... 312 frames not shown ...`, and the 5
outermost. A task's stack ends with the task's function, and a last line `task
spawned at file:line:column` gives the place of the `Task.spawn` call that
started it. A function name or file path longer than 256 bytes is cut there, at
a character boundary, and ends with `...`.

`--ai` puts the same lines under `  stack:` after the `source:` line. `--json`
adds a `stack` array of objects with the keys `column`, `file`, `function` and
`line` (and `repeat` for a merged line, `tail: true` after a tail call),
innermost first; `stack_omitted` with the number of frames not shown; and, for a
task, `spawned_at` with `column`, `file` and `line`. The keys stay sorted, so
`spawned_at`, `stack` and `stack_omitted` come after `range` and before `task`.
Every `RUNTIME-` diagnostic that is raised while a task runs has the stack,
`RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` included, and so does a task
crash line. `System.exit`, the out-of-memory exit, and failures outside any task
(the stall check `every task is waiting and nothing can wake them`, a failed
flush of output) have none.

The code carries the prefix of the stage that failed: `LEX-`, `PARSE-`, `CHECK-`
(before running), or `RUNTIME-` (while running). The VM compiler stages use
`LOWER-` and `BYTECODE-`. Each stage stops at the first error. The diagnostics
that an agent most needs to tell apart are: invalid syntax, unknown name,
incompatible type, wrong arity, unknown or missing field, missing return, and
runtime error.

Names and forms from other languages get a `help` that names the Agentica form.
A method hint is given only when the suggested method exists for the receiver's
type:

- **Written:** `len(x)`, `x.len`
  - **Help:** `x.size` for lists and maps, `s.length` for strings

- **Written:** `str(x)`, `x.to_string()`
  - **Help:** `x.to_s` or `"#{x}"`

- **Written:** `inspect(x)`
  - **Help:** `x.inspect`, or `IO.inspect(x)` to print it

- **Written:** `println(x)`
  - **Help:** `puts(x)`

- **Written:** `input()`, `read_line()`
  - **Help:** `gets` (a Result) or `gets!`

- **Written:** `range(n)`
  - **Help:** a range: `for i in 0...n`, or `n.times do \|i\| ... end`

- **Written:** `int(x)`, `float(n)`, `Int.to_float(n)`
  - **Help:** `x.to_i`, `n.to_f`

- **Written:** `x.lower`, `x.upper`, `x.startswith(...)`
  - **Help:** `downcase`, `upcase`, `start_with?`

- **Written:** `x.nil?`
  - **Help:** `x == nil`

- **Written:** `xs.select`, `xs.collect`, `xs.detect`, `xs.inject`, `xs.reject`
  - **Help:** `filter`, `map`, `find`, `reduce`; `reject` is `xs.filter do \|x\|
    !cond end`. Each method has one name

- **Written:** `(1..5).map`, `.select`, `.find`, `.sum`
  - **Help:** a range has no list methods: `(1..5).to_a.map do \|x\| ... end`

- **Written:** `None`, `null`
  - **Help:** `nil`

- **Written:** `elif`, `elseif`, `else if`
  - **Help:** `elsif`

- **Written:** `let x = 5`, `var x = 5`, `const x = 5`
  - **Help:** `x = 5` or `x: Int = 5`

- **Written:** `match x`, `when 1` in a `case`
  - **Help:** `case x`, arms as `1 -> ...`

- **Written:** `if x then`
  - **Help:** a newline after the condition

- **Written:** `x = 1;` (`LEX-UNEXPECTED-CHAR`)
  - **Help:** no semicolons: end the statement with a newline

- **Written:** `'+'`, `'abc'`, `` `abc` `` (`LEX-UNEXPECTED-CHAR`)
  - **Help:** strings use double quotes; a character is a one-character String:
    `"+"`

- **Written:** bytes that are not valid UTF-8 in a source file
  (`LEX-INVALID-UTF8`)
  - **Help:** source files are UTF-8: save the file as UTF-8 text

- **Written:** `xs << x` (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** lists are immutable and have no `<<`: `xs = xs.push(x)`

- **Written:** `<<NAME`, `<<-NAME`, `<<~'NAME'`, `<<~name`
  (`LEX-UNEXPECTED-CHAR`)
  - **Help:** the only heredoc is `<<~NAME`, with the name in capitals; `\#`
    writes a `#` that starts no interpolation

- **Written:** a heredoc with one line of text or none (`LEX-HEREDOC-ONE-LINE`)
  - **Help:** a heredoc is for two lines or more; write one line as a string
    literal, `"text\n"`

- **Written:** a tab in the indentation of a heredoc (`LEX-HEREDOC-INDENT`), a
  heredoc with no end line (`LEX-UNTERMINATED-HEREDOC`)
  - **Help:** indent with spaces; end the heredoc with a line that holds only
    its name

- **Written:** `// note`, `/* note */` (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** comments start with `#`; `4 // 2` has no `//` operator, `/` on two
    Ints truncates

- **Written:** a `##` doc block that is not directly above a `def`, `struct`,
  `enum`, field or variant (`PARSE-DETACHED-DOC`)
  - **Help:** put the doc block on the lines just above what it documents, with
    no blank line or `#` comment between; use `#` for a note that documents
    nothing

- **Written:** a function before a `struct`, `enum` or type alias, a private
  `def` before an `export def`, a constant after a declaration that is not an
  import or a constant, an `import` after a declaration (`CHECK-DECL-ORDER`)
  - **Help:** keep the file order: module doc and imports, then constants, then
    `struct`, `enum` and type aliases, then `export def`, then `def`

- **Written:** `Limit = 1`, `X = 1`, `maxDepth = 1` at the top level
  (`PARSE-CONSTANT-NAME`)
  - **Help:** a constant name is capitals, digits and `_`, at least two
    characters: `LIMIT`; the help suggests `MAX_DEPTH` for `MaxDepth`

- **Written:** `LIMIT = make()` with a `def`, `&make`, a `while` loop, or a
  builtin with effects such as `IO.gets!()` in a constant
  (`CHECK-CONSTANT-EXPRESSION`)
  - **Help:** a constant is built from literals, constructors, operators, other
    constants and builtins without effects; compute anything else in a function

- **Written:** `JOBS: Channel[Int] = Channel.new(1)` in a constant
  (`CHECK-CONSTANT-TYPE`)
  - **Help:** a constant holds data: numbers, text, collections, structs and
    enums of those; functions, tasks, channels and handles are not data

- **Written:** `A = B + 1` with `B = A + 1` (`CHECK-CONSTANT-CYCLE`)
  - **Help:** break the loop; the help lists the constants around it, `A -> B ->
    A`

- **Written:** `case x` with `LIMIT -> ...` (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** a constant is not a pattern; compare with `if x == LIMIT`

- **Written:** `LIMIT = 2` or `LIMIT += 1` inside a function
  (`PARSE-INVALID-ASSIGNMENT-TARGET`)
  - **Help:** constants are set at the top level and never change; use a local
    with a lowercase name

- **Written:** `Limits.MAX` or `Limits.MAX()` for a constant `MAX`
  (`CHECK-IMPORT-NAME`)
  - **Help:** `import {MAX} from "limits"`, then use `MAX`; a constant is not
    reached through the alias

- **Written:** code nested more than 1,000 levels deep (`PARSE-TOO-DEEP`):
  parentheses, brackets, blocks, statements, prefix operators, type arguments,
  or a chain of operators or `.` suffixes that, with the nesting around it,
  passes 1,000 levels
  - **Help:** split the code into smaller functions, or name the parts of a long
    expression with bindings

- **Written:** a tree of expressions and statements more than 1,000 levels deep,
  or an alias expansion with more than 1,000 type references (`CHECK-TOO-DEEP`):
  every expression and statement inside another counts one level, and the tree
  can be deeper than the parser's count, because the right operand of the first
  operator of a chain hangs below the whole chain (`x + (x + (...) + x + x) + x
  + x`)
  - **Help:** split the code into smaller functions, name the parts of a long
    expression with bindings, or simplify the alias chain

- **Written:** a statement or an extra `end` at the top level
  (`PARSE-TOP-LEVEL-STATEMENT`)
  - **Help:** statements go inside `def main() -> Void ... end`; an extra `end`
    closes nothing; a stray `else` or `elsif` has no matching `if`; a file holds
    only `def`, `struct`, `enum`, type aliases (`type Name = Type`), `import`,
    `export` and constants (`NAME = value`)

- **Written:** `user.with()`, `user.with(31)`, `user.with(age)`
  (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** a struct update names each field it changes, one or more:
    `user.with(age: 31)`

- **Written:** `x.with(age: 31)` where `x` is not a struct
  (`CHECK-UNKNOWN-METHOD`)
  - **Help:** `with` copies a struct with some fields changed; the value before
    `.with` must be a struct

- **Written:** `CONFIG.with()` on a constant of a struct type
  (`CHECK-UNKNOWN-METHOD`; a lowercase `user.with()` is
  `PARSE-UNEXPECTED-TOKEN`)
  - **Help:** `with` needs the fields to change, as in `.with(field: value)`;
    the help lists the fields

- **Written:** a field named `with` of type `Fn[...]` (`CHECK-REDEFINED-NAME`)
  - **Help:** rename the field: `value.with(...)` is always the struct update

- **Written:** a parameter without a default after one with a default, such as
  `def f(a: Int = 1, b: Int)` (`CHECK-DEFAULT-ORDER`)
  - **Help:** give `b` a default, or move the parameters with a default to the
    end; only a last `Fn` parameter may stay without one, so a block can fill it

- **Written:** a default that is not a constant, such as `b: Int = make()`, `b:
  Int = a`, `b: Int = 1 + 2`, `b: List[Int] = [1]` (`CHECK-DEFAULT-VALUE`)
  - **Help:** a default is a literal, `true`, `false`, `nil`, `[]`, `{}` or an
    enum variant without a payload; make the parameter required and pass the
    value at the call

- **Written:** `f()` or `f(1, 2, 3)` for `def f(a: Int, b: Int = 1)`
  (`CHECK-ARITY`)
  - **Help:** a call takes from the number of parameters without a default to
    the number of all parameters (`1 to 2 arguments`)

- **Written:** `s.chars`, `s.each_char`
  - **Help:** `s.split("")`, and `s.at(i)` for one character

- **Written:** `s.matches?(...)`, `s.match?(...)`, `s.scan(...)`
  - **Help:** no regular expressions: `contains?`, `starts_with?`, `ends_with?`,
    `index_of`

- **Written:** `s.gsub`, `s.sub`, `s.substring`, `s.substr`, `s.char_at`,
  `s.ord`, `n.chr`, `s.empty?`, `s.isdigit`
  - **Help:** `s.replace`, `s.slice(start, length)` (length is end - start),
    `s.at(i)`, `s.code`, `String.from_code(n)`, `s.length == 0`, `s.to_i.ok?`

- **Written:** `s.chomp`, `s.chars` or another String method on a `Result` (for
  example from `IO.gets`)
  - **Help:** unwrap first with `r.unwrap!`, or read with `IO.gets!`

- **Written:** `s.error?` on a String
  - **Help:** only a Result has `ok?` and `message`

- **Written:** `s[0]` on a String (`CHECK-NOT-INDEXABLE`)
  - **Help:** `s.at(i)`, `s.slice(start, length)`, or `s.split("")`

- **Written:** `n * 1.5` with an Int `n` (`CHECK-TYPE-MISMATCH`)
  - **Help:** `n.to_f * 1.5`; `x.to_i!` truncates a Float; `s.to_i!` / `n.to_s`
    for String and number

- **Written:** `a < b` on Strings (`CHECK-TYPE-MISMATCH`)
  - **Help:** `< <= > >=` take numbers only; compare with `==` and `!=`, order a
    list with `xs.sort`

- **Written:** `m = {}`, `xs = []`, `s = Set.new([])` (`CHECK-EMPTY-MAP-TYPE`,
  `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-SET-TYPE`)
  - **Help:** annotate: `m: Map[String, Int] = {}`, `s: Set[Int] = Set.new([])`

- **Written:** a loop, `if` or `case` as the last statement
  (`CHECK-MISSING-RETURN`)
  - **Help:** a loop is not a return; each branch or arm must return, or return
    after it

- **Written:** `while x {`, `if x {`, `else {`, `for x in xs {`, `case x {`,
  `def f() -> T {`, `do \|x\| {` (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** blocks have no braces: `while cond` ... `end`

- **Written:** a `}` with no `{` open (`LEX-UNMATCHED-DELIMITER`), an unclosed
  `{` (`LEX-UNCLOSED-DELIMITER`)
  - **Help:** blocks end with `end`, not `}`

- **Written:** `fn(x: Int) ...`, `lambda do ... end`, a `do` block with no call
  - **Help:** a block after a call (`xs.map do \|x\| ... end`) or `&name`

- **Written:** `Hash.new`, `Map.new`, `Array.new`, `List.new`
  - **Help:** a typed literal: `m: Map[String, Int] = {}`, `xs: List[Int] = []`

- **Written:** `Set.empty`, `s.contains?(x)`, `s.member?(x)`
  - **Help:** `Set.new([])` with an expected type, `s.include?(x)`

- **Written:** `continue`
  - **Help:** `next`

- **Written:** `x \|> f`, `x \|> r.field`, `x \|> xs[0]`, `x \|> f(1).g`
  (`PARSE-PIPE-TARGET`)
  - **Help:** a call with parentheses on the right; wrap the expression in
    parentheses and use `.` on the result: `(x \|> f()).unwrap!`

- **Written:** `x \|> String.trim()` (`CHECK-PIPE-METHOD`)
  - **Help:** the method form: `x.trim`

- **Written:** `break if x`, `next if x`
  - **Help:** `if x`, then `break` on its own line, then `end`

- **Written:** `loop do ... end`
  - **Help:** `while true ... end`, or a `while` condition

- **Written:** `puts(x) if ok`, `if x do`
  - **Help:** `if ok ... end`; an `if` condition ends with a newline

- **Written:** `Result.Some(x)` and other unknown Result variants
  - **Help:** `Result.Ok(x)` / `ok(x)`, `Result.Err(m)` / `error(m)`

- **Written:** `Color.Red` with no `Color` enum or import
  - **Help:** `enum Color`, or `import Color from "path"`

- **Written:** a `Result[T]` where `T` is expected (`n: Int = s.to_i`)
  - **Help:** a `!` form (`s.to_i!`), `Result.unwrap!`, or `try`

- **Written:** `HttpWire.exchange(...)` or another `HttpWire` call outside
  `std/http`
  - **Help:** `import HTTP from "std/http"`, then `HTTP.get`, `HTTP.post` or
    `HTTP.request`

- **Written:** `LogRegistry.level()` or another `LogRegistry` call outside
  `std/logger`
  - **Help:** `import Logger from "std/logger"`, then `Logger.info`,
    `Logger.attach` and the other `Logger` functions

- **Written:** `import` followed by a string, the path-first form of earlier
  versions (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** `import Models from "models"`: the alias comes first, then `from`
    and the path

- **Written:** `import Mod, {name} from "path"`, `import {} from "path"`,
  `import {a b} from "path"` (`PARSE-UNEXPECTED-TOKEN`)
  - **Help:** one line does one thing: write `import Mod from "path"` and
    `import {name} from "path"` on two lines; a name list has at least one name,
    with commas between names

- **Written:** `import {Token as token} from "path"`, `import {lex as Lex} from
  "path"`, `import {MAX as Max} from "path"` (`CHECK-IMPORT-RENAME`)
  - **Help:** a struct or an enum is renamed to a type name (a capital first
    letter), a function to a lowercase name and a constant to another constant
    name (capitals and underscores)

- **Written:** an imported name (or the new name after `as`) that is also a
  declaration of the file, an alias, another imported name, a builtin function
  such as `puts` or a reserved type name such as `Int` (`CHECK-REDEFINED-NAME`)
  - **Help:** rename the import: `import {name as other} from "path"`

- **Written:** `M.nme` or `import {nme} from "path"` when module `M` exports
  `name` (`CHECK-IMPORT-NAME`)
  - **Help:** the help suggests the closest export of `M` (`did you mean
    "name"?`); it never suggests a private name, and it stays empty when no
    export is close

- **Written:** `Logger.error(...)` (`CHECK-IMPORT-NAME`)
  - **Help:** `Logger.err(...)`; `error` is a reserved name, so the function for
    the error level is `err`

- **Written:** `HTTP.get(...)` or another `HTTP.` call without the import
  - **Help:** `import HTTP from "std/http"`

- **Written:** `HTTP.respond(writer, ...)`, `HTTP.begin`, `HTTP.write`,
  `HTTP.write_bytes`, `HTTP.finish` with the import (`CHECK-IMPORT-NAME`)
  - **Help:** a handler that returns its whole response: `return
    ok(HttpResponse(status: 200, headers: [], body: text))`

- **Written:** `Request` or `HttpWriter` as a type (`CHECK-UNKNOWN-TYPE`)
  - **Help:** `def handle(request: HttpRequest) -> Result[HttpResponse]`

- **Written:** a type alias cycle (`CHECK-TYPE-ALIAS-CYCLE`)
  - **Help:** break the cycle; aliases expand to the type they name, so `type
    Names = List[String]` is valid

- **Written:** `Grid(...)` when `Grid` is a type alias (`CHECK-UNKNOWN-TYPE`)
  - **Help:** construct the struct named by the alias, or use a value of the
    aliased builtin type

- **Written:** `Task.async_stream(...)`, `Parallel.map(...)`
  - **Help:** `Task.map(items, limit, timeout_ms) do |x| ... end`, where the
    block gives a `Result`

- **Written:** `Task.async(...)`, `Thread.new(...)`
  - **Help:** `Task.spawn(&f, arg)`, then `Task.await(task)` for its result

- **Written:** `Enumerator.new(...)`, `Fiber.new(...)`
  - **Help:** a producer task that sends into a channel: `Task.spawn(&produce,
    ch)`, then `ch.recv(timeout_ms)`

- **Written:** `xs.lazy` on a list or a range
  - **Help:** lists are eager; read a source that is too big for a list in a
    `while` loop

- **Written:** `Agent.start_link(...)` and other `Agent.` calls
  - **Help:** return values from tasks and combine them with `reduce`, or keep
    the state in one task that receives on a `Channel`

- **Written:** `Mutex.new`
  - **Help:** one owner task that receives requests on a `Channel`

- **Written:** `SizedQueue.new(n)`
  - **Help:** `Channel.new(n)` with an annotated variable

- **Written:** `Channel.new(n)` with no expected type (`CHECK-EXPECTED-TYPE`)
  - **Help:** annotate it: `ch: Channel[Int] = Channel.new(8)`

Diagnostics refer to Agentica and never expose host exceptions or tracebacks:
the frames of a stack are Agentica functions.
