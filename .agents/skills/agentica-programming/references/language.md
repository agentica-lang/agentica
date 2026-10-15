# Core language

Read this for the exact rule behind a checker error or a core question that SKILL.md does not answer. Builtin methods and `to_s` are in `builtins.md`.

## Program shape

- A file has top-level `def`, `struct`, `enum`, and `import` declarations; no statements run at top level. `export` may prefix a function, struct, or enum.
- Declarations keep one order in every file: the module doc and `import`s, then `struct` and `enum` (exported or not, in any order), then `export def` functions, then private `def` functions. The first declaration out of place is `CHECK-DECL-ORDER`, at its start. The order is style only: a function may call a function declared later.
- The root file needs exactly one `def main() -> Void` with no parameters. Only that entrypoint runs.
- Blocks end with `end`; indentation is for reading only. `#` starts a comment to the end of the line.
- A newline ends a statement. Inside `(...)`, `[...]`, and `{...}` an expression may span lines, and a trailing comma is allowed. To split a long expression, wrap it in parentheses.
- Reserved words: `def struct enum case do import export end if elsif else while for in return try true false nil and or not`.
- Extra blank or comment lines between statements are ignored.
- `##` lines are doc comments. A `##` block on the lines directly above a `def`, `struct`, `enum`, field or variant documents it (Markdown text); the first block of a file, followed by a blank line, documents the module. A `##` after code on the same line is a plain comment. Any other `##` block is `PARSE-DETACHED-DOC`, and a doc block does not count as the blank line between declarations.
- A module function with no arguments may drop its parentheses, builtin or through an import alias (`IO.gets!`, `IO.eof?`, `Util.reset`). `f = Util.helper` is a call; `&Util.helper` is the function value.
- `--max-steps N` bounds execution to N expression or statement entries across all tasks (`RUNTIME-STEP-LIMIT`); it is not an I/O timeout.

## Types

| Type | Notes |
|---|---|
| `Int` | signed 64-bit; overflow is a runtime error |
| `Float` | IEEE 754 double |
| `Bool` | `true` / `false` only |
| `String` | Unicode text |
| `Nil` | the single data value `nil` |
| `Void` | completion without a usable value; no literal |
| `Process` | opaque child process; inspect prints `<Process>` |
| `List[T]` | homogeneous, immutable, indexed from 0 |
| `Map[K, V]` | homogeneous, immutable; `K` is `Int` or `String`; keeps insertion order |
| `Set[T]` | distinct values, immutable; `T` is `Int` or `String` (`CHECK-SET-ELEMENT-TYPE` otherwise); keeps first-insertion order; prints as `Set[1, 2]`; no `==`, not JSON-encodable |
| `Result[T]` | `ok(value)` or `error(message)`; the error is always String; exactly one type argument |
| `Range` | `a..b` (includes `b`) or `a...b` (excludes it) over `Int`; prints as `1..5` |
| `Json` | opaque JSON value; use `JSON` functions to access it |
| `Fn[A, ..., R]` | function value (a block or `&name`); last type is the return; `Fn[Void]` takes no arguments |
| `Task[R]` | opaque lightweight task; exactly one result type |
| `Await[T]` | builtin enum from `Task.await(task, timeout_ms)`: `Await.Done(value)` or `Await.TimedOut`; reserved name; see `tasks.md` |
| `Channel[T]` | opaque bounded queue between tasks (VM only); see `tasks.md` |
| network handles | opaque `Socket`, `Listener`, `HttpClient`, `HttpServer` |
| `LogLevel` | builtin enum of `std/logger`: `LogLevel.Debug`, `Info`, `Warning`, `Error`; reserved name; see `logger.md` |
| builtin records | `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions`, `HttpServerOptions`, `FileInfo`, `ProcessOutput`, `LogEvent` |
| `Name` | a struct you declare; fields are typed and immutable |

`Option[T]` is not builtin; declare it as an enum if you need it. Type names start with an uppercase letter. Variable, function, and field names start with a lowercase letter or `_`.

## Void

`Void` has no literal or usable payload. It is allowed as a function return, the final type of `Fn`, or the completion type of `Result` and `Task`. Bare Void variables, parameters, fields, List elements, and Map values are `CHECK-VOID-TYPE`; wrappers such as `List[Result[Void]]` are valid.

A Void call may be a statement, or be forwarded from a Void function with `return another_void_call()`. Assignment, argument passing, construction, operators, and inspection of a bare completion fail with `CHECK-VOID-VALUE`. The same holds for `Result.unwrap!(Result[Void])`, `Task.await(Task[Void])`, and a successful `try` on `Result[Void]`.

`ok()` infers `Result[Void]` and prints `ok()`; `ok(nil)` is `Result[Nil]` and prints `ok(nil)`. A `Result[Void]` function returns `ok()` or `error(message)` explicitly; `try` still needs a Result-returning function. `Result.unwrap_or` needs a data fallback and cannot operate on `Result[Void]`.

## Declarations

```ruby
struct User
  name: String
  age: Int
end

enum Option[T]
  Some(T)
  None
end
```

- Leave a blank line after the `end` of each `def`, `struct`, and `enum` before the next declaration (`PARSE-MISSING-BLANK-LINE`).
- Every parameter and the return type need an annotation.
- Structs, enums, and functions are top level only. An enum's type parameters apply only to its payloads; there are no generic functions or structs, no user methods, no nested functions, no default arguments, and no overloading. Closures are blocks.
- Source nesting (parentheses, calls, blocks, `if`, types) may go 1000 levels deep at most, and each operator of a chain or `.` suffix counts a level too (`PARSE-TOO-DEEP`; a chain of 1,000 `+` already fails).
- Functions may be called before they are declared, and may be recursive. Nested calls go 10000 deep at most (`RUNTIME-STACK-OVERFLOW`); tail calls do not count toward that depth. Only `return f(...)` whose value is directly a call to a user function is a tail call: `return 1 + f(n - 1)` (the call inside a larger expression) and calls to builtins are not.
- So recursion over a big list or a big count is written in tail form with an accumulator (and an index for a list), or uses `for`, `map`, `filter` or `each`. `return count(n - 1, acc + 1)` runs for 1,000,000 calls; `return 1 + count(n - 1)` fails with `RUNTIME-STACK-OVERFLOW` at that size.
- Build a list with `xs = xs.push(x)` in a loop. `push` is cheap because lists are persistent vectors, so there is no need for the prepend-then-reverse habit of Elixir or Lisp.
- A non-Void function must `return` on every path; a loop does not count, and the last expression is not returned implicitly. `return` alone, or reaching the end, completes a Void function. A `Nil` function returns `nil` explicitly.

## Statements

- The first assignment to a name creates it in the current block. Later assignments change its value, never its type. An annotation is allowed only on creation (`total: Float = 0.5`).
- `x += e`, `-=`, `*=`, `/=`, `%=` mean `x = x op e`; `x` must already exist.
- A name created in a block is not visible after that block's `end`. A new variable cannot reuse a name visible in an outer scope (no shadowing).
- `for item in items` binds a read-only variable; it cannot be assigned. `for` takes a `List[T]`, a `Set[T]` (in first-insertion order) or a `Range`, and runs zero times for an empty or reversed range; a range is never built as a list. Write `0...n`, `n.times`, `a.upto(b)`, or `a.downto(b)`; a `for` over a range never counts down.
- `case value` ... `end` is a statement. Arms are `pattern -> block`; a short arm may hold one simple statement on the arrow line (`1 -> puts("one")`). A `do` after the value is allowed but not needed. Bindings are local to their arm.
- Patterns are primitive literals, `_`, or qualified enum variants with one binding or `_` per payload position. Nested patterns and guards are not supported.
- Enum cases cover every variant or use `_`. A non-enum case, including `Bool` and `Nil`, requires a final top-level `_`. Duplicate or unreachable arms are checker errors.
- `if` and `while` conditions must be `Bool`. There is no truthiness.
- `break` leaves the innermost `while` or `for`; `next` skips to its next iteration. Each stands alone on its line. They cannot cross a block or function (`CHECK-LOOP-CONTROL`). Inside a block, `return` leaves the block.
- Assignment is a statement, not an expression. There is no `x[i] = v`, `x.f = v`, or `continue`.

## Expressions

- Literals: `42`, `3.14`, `1_000` (a `_` between digits is only visual; a trailing, double or dot-side `_` is `LEX-INVALID-NUMBER`), `"text"` (escapes `\" \\ \# \n \r \t`), `true`, `false`, `nil`. A minus sign is an operator, not part of the literal.
- Interpolation: `"total: #{n + 1}"` is a `String`. Strings go in as is, `Json` as its JSON text, other data values in their `IO.inspect` form. Keep the expression on one line; `\#{` is literal text. `case` patterns and `import` paths take plain strings only.
- Lists `[1, 2, 3]`; maps `{"a": 1, "b": 2}`. A repeated key keeps the last value at its first position, and `Map.put` on an existing key also keeps that position.
- `[]`, `{}` and `Set.new([])` need a known type (annotation, parameter, field, or function result): `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`, `CHECK-EMPTY-SET-TYPE`. A non-empty list needs one element type.
- Struct construction uses every field exactly once, named, in any order: `User(name: "Ana", age: 25)`.
- Enum variants are qualified by their type. Payload variants take positional arguments (`Option.Some("hi")`); nullary variants take `Option.None` or `Option.None()`. Generic arguments come from payloads and expected types; a nullary generic variant needs expected-type context.
- Field access `user.name`; index `items[0]` and `stock["apple"]`. Strings cannot be indexed. List indexing takes O(log32 n) time (at most four steps for a million items); `for` visits the items in order.
- `&name` references a declared top-level function without capturing locals: `f: Fn[Int, Int] = &double`, then `f.call(21)`. A block is also a function value and captures locals. Function values can be stored in containers, fields, parameters, and returns; signatures must match exactly. Bare function names are not values. No standalone lambdas, equality, or JSON encoding; inspect prints `<Fn>`.

Operators, from highest to lowest precedence:

| Level | Operators |
|---|---|
| 1 | call, `.field`, `[index]`, `( )` |
| 2 | unary `-`, `not` / `!`, `try` |
| 3 | `*` `/` `%` |
| 4 | `+` `-` |
| 5 | `\|>` (pipe) |
| 6 | `<` `<=` `>` `>=` |
| 7 | `==` `!=` |
| 8 | `and` / `&&` |
| 9 | `or` / `\|\|` |
| 10 | `..` `...` (ranges, no chaining) |

- `+ - * /` take two numbers of the same type; there is no implicit conversion. `+` also joins two Strings.
- `/` on Int truncates toward zero. `%` takes two Ints. A zero divisor is a runtime error, also for Float.
- `< <= > >=` take two numbers of the same type. Comparisons do not chain.
- `==` and `!=` take two values of the same primitive type (Int, Float, Bool, String, Nil), or two ranges. Lists, maps, sets, structs, Results, Json, and Fn values cannot be compared (two sets are equal when `a.subset?(b) and b.subset?(a)`).
- `&&`, `||`, `!` take Bool and short-circuit; `and`, `or`, `not` are the same operators. `!` binds tightly, so write `!(a >= b)`. A `!` right after a name is part of the name (`read!`).
- Operands are evaluated left to right.
- `x |> f(a)` means `f(x, a)`. The right side must be a call with parentheses (`f(a)`, `Alias.f(a)`), optionally after `try`; pipes group to the left (`x |> f() |> g()` is `g(f(x))`). A builtin with a method form is written with `.`; see `PARSE-PIPE-TARGET` and `CHECK-PIPE-METHOD` in `diagnostics.md`.

## Blocks and closures

A block is a function written at the call site as the last argument: `xs.map do |x| x * 2 end`, `run(5) do |n| n + 1 end`.

- Write `do |a, b| ... end` or `do ... end` after the call's `)`, or after a method name with no parentheses (`xs.each do`). A user function needs parentheses (`run(5) do ... end`); a function through an import alias may drop them (`Util.start do ... end`). The called function's last parameter must be a `Fn` (`CHECK-BLOCK-TARGET`). Never `do || ... end` or `{ |x| ... }`.
- Parameter types come from the call; annotate when there is no context: `do |x: Int| ... end` (`CHECK-BLOCK-TYPE` otherwise).
- The last expression is the block's value; `return value` leaves only the block. A non-Void block must give a value on every path. `try` in a block needs the block to return a Result known from the call (not in `map` or `sort_by`), and it ends with `ok(...)`.
- `case`, `while`, and `for` headers may end with an optional `do` (`while !done do`, `for x in xs do`); that `do` is never a block. To put a call with a block in such a header, wrap it: `case (xs.map do |x| x end) do`.
- Blocks capture values when created; later outer changes do not affect them. A block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`); build the value with `map`, `reduce`, or a `for` loop. Block parameters cannot reuse visible names.
- A block is a `Fn[...]` value: return it, store it, pass it to `Task.spawn`, or make a BDD step with `BDD.step("pattern") do |ctx, args| ... end`.
- `List.each` runs a block per element; `List.any?` and `List.all?` stop at the first deciding element.

## Result and try

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
```

- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload against T, even for `ok([])` or `ok({})`.
- `error("bad")` needs an expected Result type from an annotation, an existing binding, a return, an argument, a field, or a typed container element. `r = error("bad")` alone is `CHECK-RESULT-TYPE`.
- `try` evaluates its Result operand once: success gives the payload; an error returns from the current function. Only a Result-returning function may use it. The operand and the function's success type may differ. `try` binds like unary `not`; use parentheses for a larger operand. Success paths still need explicit returns. The expected type of a `try` supplies `Result[T]` to its operand; the function's return type alone does not infer that payload.
- `Result.unwrap!` halts with `RUNTIME-UNWRAP-ERROR` on an error, and passes its expected output T into the operand as `Result[T]`. `Result.unwrap_or` uses the expected T or infers it from the default, and evaluates both arguments, left to right, even on success.
- `Result.ok?` and `Result.message` need a known Result type; they cannot infer a bare error's payload. `Result.message` is `""` for a success.
- `ok(false)` and `ok(nil)` are successes. Results nest and may hold lists, maps, and structs; they have no equality, fields, or indexing.
- Lists and maps infer their type from the first element: `[ok(1), error("bad")]` infers, the reverse order needs an annotation.
- Non-bang conversions (`String.to_int`) use the same syntax and 64-bit bounds as the bang forms, but invalid text returns an error. Unrelated runtime errors are not converted to Results. `IO.gets` returns a line without LF, CR, or CRLF; a blank line is `ok("")`, not end of input.
- `Result.Ok(x)` and `Result.Err(m)` are the same as `ok(x)` and `error(m)`, as values and as `case` patterns. `Result.Ok(_)` discards a payload, including for `Result[Void]`.

```ruby
def read_age(text: String) -> Result[Int]
  age = try text.to_i
  return ok(age)
end

def main() -> Void
  age = read_age("bad")
  if !age.ok?
    puts(age.message)
  end
  puts(age.unwrap_or(0).to_s)
end
```

## Forms from other languages

These are rejected with a `help` line that names the Agentica form: `let x = 5`, `match x`, `when 1`, `if x then`, `elif`, `fn(x: Int)`, `lambda do`, `len(x)`, `Hash.new`, `break if x`, `loop do`, `puts(x) if ok`, `;`, and `while x {` ... `}`.
