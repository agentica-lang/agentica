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
| `fn(x: Int) ...`, `lambda do ... end`, a `do` block with no call | a block after a call (`xs.map do \|x\| ... end`) or `&name` |
| `Hash.new`, `Array.new` | a typed literal: `m: Map[String, Int] = {}`, `xs: List[Int] = []` |
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
| `HTTP.get(...)` or another `HTTP.` call without the import | `import "std/http" as HTTP` |
| `HTTP.respond(writer, ...)`, `HTTP.begin`, `HTTP.write`, `HTTP.write_bytes`, `HTTP.finish` with the import (`CHECK-IMPORT-NAME`) | a handler that returns its whole response: `return ok(HttpResponse(status: 200, headers: [], body: text))` |
| `Request` or `HttpWriter` as a type (`CHECK-UNKNOWN-TYPE`) | `def handle(request: HttpRequest) -> Result[HttpResponse]` |
| `Enumerator.new(...)`, `Fiber.new(...)` | a producer task that sends into a channel: `Task.spawn(&produce, ch)`, then `ch.recv(timeout_ms)` |
| `xs.lazy` on a list or a range | lists are eager; read a source that is too big for a list in a `while` loop |
| `Agent.start_link(...)` and other `Agent.` calls | return values from tasks and combine them with `reduce`, or keep the state in one task that receives on a `Channel` |
| `Mutex.new` | one owner task that receives requests on a `Channel` |
| `SizedQueue.new(n)` | `Channel.new(n)` with an annotated variable |
| `Channel.new(n)` with no expected type (`CHECK-EXPECTED-TYPE`) | annotate it: `ch: Channel[Int] = Channel.new(8)` |

Diagnostics refer to Agentica and never expose host exceptions or tracebacks.
