## 7. Diagnostics for agents

Each error has a stable code, a file, a line and a column, a concrete explanation, and the source line with a mark under the span. Spans travel from the tokens to the AST.

```text
example.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

When the checker knows the fix, the diagnostic ends with a `= help:` line.

`agentica --ai` and `agentica --json` print the same diagnostic as compact text, or as one JSON object. In `--json` mode, when a diagnostic ends the run, it is the last line of stderr, except that a warning about the flush of files or output (§6) can follow it when the end-of-run flush fails or runs out of time. Task crash lines (with `"task": true`), the unobserved-crash summary (`{"unobserved_crashes": N, "first": "..."}`) and the flush warning of §6 are not the run's diagnostic.

A runtime diagnostic of a running task also shows the call stack of the task that failed, innermost frame first, in all three formats. There is no flag. The stack is shown when the failing task has more than one frame or is not `main`; a failure directly in `main` looks as it does without a stack.

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

A frame line is the function's declared name and the place it was running. For the innermost frame that is the place of the error, and for each caller it is the call it waits on. A block shows as `block`, a function from an imported file shows its name (the file is in the place), and the builtins that run a block (`xs.map`) are skipped, since the frame below already points at the call. A frame that a tail call replaced is gone: the frame left ends with `(after a tail call)`, so a reader knows that callers are missing there. Neighbouring frames with the same function and place are one line with a count, as in `walk at tree.agc:9:12 (9998 times)`, so a runaway recursion that ends in `RUNTIME-STACK-OVERFLOW` takes a few lines. After that merge at most 20 lines show: the 15 innermost, a line `... 312 frames not shown ...`, and the 5 outermost. A task's stack ends with the task's function, and a last line `task spawned at file:line:column` gives the place of the `Task.spawn` call that started it. A function name or file path longer than 256 bytes is cut there, at a character boundary, and ends with `...`.

`--ai` puts the same lines under `  stack:` after the `source:` line. `--json` adds a `stack` array of objects with the keys `column`, `file`, `function` and `line` (and `repeat` for a merged line, `tail: true` after a tail call), innermost first; `stack_omitted` with the number of frames not shown; and, for a task, `spawned_at` with `column`, `file` and `line`. The keys stay sorted, so `spawned_at`, `stack` and `stack_omitted` come after `range` and before `task`. Every `RUNTIME-` diagnostic that is raised while a task runs has the stack, `RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` included, and so does a task crash line. `System.exit`, the out-of-memory exit, and failures outside any task (the stall check `every task is waiting and nothing can wake them`, a failed flush of output) have none.

The code carries the prefix of the stage that failed: `LEX-`, `PARSE-`, `CHECK-` (before running), or `RUNTIME-` (while running). The VM compiler stages use `LOWER-` and `BYTECODE-`. Each stage stops at the first error. The diagnostics that an agent most needs to tell apart are: invalid syntax, unknown name, incompatible type, wrong arity, unknown or missing field, missing return, and runtime error.

Names and forms from other languages get a `help` that names the Agentica form. A method hint is given only when the suggested method exists for the receiver's type:

| Written | Help |
|---|---|
| `len(x)`, `x.len` | `x.size` for lists and maps, `s.length` for strings |
| `str(x)`, `x.to_string()` | `x.to_s` or `"#{x}"` |
| `inspect(x)` | `x.inspect`, or `IO.inspect(x)` to print it |
| `println(x)` | `puts(x)` |
| `input()`, `read_line()` | `gets` (a Result) or `gets!` |
| `range(n)` | a range: `for i in 0...n`, or `n.times do \|i\| ... end` |
| `int(x)`, `float(n)`, `Int.to_float(n)` | `x.to_i`, `n.to_f` |
| `x.lower`, `x.upper`, `x.startswith(...)` | `downcase`, `upcase`, `start_with?` |
| `x.nil?` | `x == nil` |
| `None`, `null` | `nil` |
| `elif`, `elseif`, `else if` | `elsif` |
| `let x = 5`, `var x = 5`, `const x = 5` | `x = 5` or `x: Int = 5` |
| `match x`, `when 1` in a `case` | `case x`, arms as `1 -> ...` |
| `if x then` | a newline after the condition |
| `x = 1;` (`LEX-UNEXPECTED-CHAR`) | no semicolons: end the statement with a newline |
| `'+'`, `'abc'`, `` `abc` `` (`LEX-UNEXPECTED-CHAR`) | strings use double quotes; a character is a one-character String: `"+"` |
| `// note`, `/* note */` (`PARSE-UNEXPECTED-TOKEN`) | comments start with `#`; `4 // 2` has no `//` operator, `/` on two Ints truncates |
| a `##` doc block that is not directly above a `def`, `struct`, `enum`, field or variant (`PARSE-DETACHED-DOC`) | put the doc block on the lines just above what it documents, with no blank line or `#` comment between; use `#` for a note that documents nothing |
| code nested more than 1,000 levels deep (`PARSE-TOO-DEEP`): parentheses, brackets, blocks, statements, prefix operators, type arguments, or a chain of more than 1,000 operators or `.` suffixes | split the code into smaller functions, or name the parts of a long expression with bindings |
| a statement or an extra `end` at the top level (`PARSE-TOP-LEVEL-STATEMENT`) | statements go inside `def main() -> Void ... end`; an extra `end` closes nothing; a stray `else` or `elsif` has no matching `if` |
| `s.chars`, `s.each_char` | `s.split("")`, and `s.at(i)` for one character |
| `s.matches?(...)`, `s.match?(...)`, `s.scan(...)` | no regular expressions: `contains?`, `starts_with?`, `ends_with?`, `index_of` |
| `s.gsub`, `s.sub`, `s.substring`, `s.substr`, `s.char_at`, `s.ord`, `n.chr`, `s.empty?`, `s.isdigit` | `s.replace`, `s.slice(start, length)` (length is end - start), `s.at(i)`, `s.code`, `String.from_code(n)`, `s.length == 0`, `s.to_i.ok?` |
| `s.chomp`, `s.chars` or another String method on a `Result` (for example from `IO.gets`) | unwrap first with `r.unwrap!`, or read with `IO.gets!` |
| `s.error?` on a String | only a Result has `ok?` and `message` |
| `s[0]` on a String (`CHECK-NOT-INDEXABLE`) | `s.at(i)`, `s.slice(start, length)`, or `s.split("")` |
| `n * 1.5` with an Int `n` (`CHECK-TYPE-MISMATCH`) | `n.to_f * 1.5`; `x.to_i!` truncates a Float; `s.to_i!` / `n.to_s` for String and number |
| `a < b` on Strings (`CHECK-TYPE-MISMATCH`) | `< <= > >=` take numbers only; compare with `==` and `!=`, order a list with `xs.sort` |
| `m = {}`, `xs = []` (`CHECK-EMPTY-MAP-TYPE`, `CHECK-EMPTY-LIST-TYPE`) | annotate: `m: Map[String, Int] = {}` |
| a loop, `if` or `case` as the last statement (`CHECK-MISSING-RETURN`) | a loop is not a return; each branch or arm must return, or return after it |
| `while x {`, `if x {`, `else {`, `for x in xs {`, `case x {`, `def f() -> T {`, `do \|x\| {` (`PARSE-UNEXPECTED-TOKEN`) | blocks have no braces: `while cond` ... `end` |
| a `}` with no `{` open (`LEX-UNMATCHED-DELIMITER`), an unclosed `{` (`LEX-UNCLOSED-DELIMITER`) | blocks end with `end`, not `}` |
| `fn(x: Int) ...`, `lambda do ... end`, a `do` block with no call | a block after a call (`xs.map do \|x\| ... end`) or `&name` |
| `Hash.new`, `Map.new`, `Array.new`, `List.new` | a typed literal: `m: Map[String, Int] = {}`, `xs: List[Int] = []` |
| `continue` | `next` |
| `x \|> f`, `x \|> r.field`, `x \|> xs[0]`, `x \|> f(1).g` (`PARSE-PIPE-TARGET`) | a call with parentheses on the right; wrap the expression in parentheses and use `.` on the result: `(x \|> f()).unwrap!` |
| `x \|> String.trim()` (`CHECK-PIPE-METHOD`) | the method form: `x.trim` |
| `break if x`, `next if x` | `if x`, then `break` on its own line, then `end` |
| `loop do ... end` | `while true ... end`, or a `while` condition |
| `puts(x) if ok`, `if x do` | `if ok ... end`; an `if` condition ends with a newline |
| `Result.Some(x)` and other unknown Result variants | `Result.Ok(x)` / `ok(x)`, `Result.Err(m)` / `error(m)` |
| `Color.Red` with no `Color` enum or import | `enum Color`, or `import "path" as Color` |
| a `Result[T]` where `T` is expected (`n: Int = s.to_i`) | a `!` form (`s.to_i!`), `Result.unwrap!`, or `try` |
| `HttpWire.exchange(...)` or another `HttpWire` call outside `std/http` | `import "std/http" as HTTP`, then `HTTP.get`, `HTTP.post` or `HTTP.request` |
| `LogRegistry.level()` or another `LogRegistry` call outside `std/logger` | `import "std/logger" as Logger`, then `Logger.info`, `Logger.attach` and the other `Logger` functions |
| `Logger.error(...)` (`CHECK-IMPORT-NAME`) | `Logger.err(...)`; `error` is a reserved name, so the function for the error level is `err` |
| `HTTP.get(...)` or another `HTTP.` call without the import | `import "std/http" as HTTP` |
| `HTTP.respond(writer, ...)`, `HTTP.begin`, `HTTP.write`, `HTTP.write_bytes`, `HTTP.finish` with the import (`CHECK-IMPORT-NAME`) | a handler that returns its whole response: `return ok(HttpResponse(status: 200, headers: [], body: text))` |
| `Request` or `HttpWriter` as a type (`CHECK-UNKNOWN-TYPE`) | `def handle(request: HttpRequest) -> Result[HttpResponse]` |
| `Enumerator.new(...)`, `Fiber.new(...)` | a producer task that sends into a channel: `Task.spawn(&produce, ch)`, then `ch.recv(timeout_ms)` |
| `xs.lazy` on a list or a range | lists are eager; read a source that is too big for a list in a `while` loop |
| `Agent.start_link(...)` and other `Agent.` calls | return values from tasks and combine them with `reduce`, or keep the state in one task that receives on a `Channel` |
| `Mutex.new` | one owner task that receives requests on a `Channel` |
| `SizedQueue.new(n)` | `Channel.new(n)` with an annotated variable |
| `Channel.new(n)` with no expected type (`CHECK-EXPECTED-TYPE`) | annotate it: `ch: Channel[Int] = Channel.new(8)` |

Diagnostics refer to Agentica and never expose host exceptions or tracebacks: the frames of a stack are Agentica functions.
