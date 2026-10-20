# Core language

Read this for the exact rule behind a checker error or a core question that
SKILL.md does not answer. Builtin methods and `to_s` are in `builtins.md`.

## Program shape

- A file has top-level `def`, `struct`, `enum`, type alias, `import` and
  constant declarations; no statements run at top level. `export` may prefix a
  function, struct, enum, type alias or constant.
- Declarations keep one order in every file: the module doc and `import`s, then
  constants, then `struct`, `enum` and type aliases (exported or not, in any
  order), then `export def` functions, then private `def` functions. The first
  declaration out of place is `CHECK-DECL-ORDER`, at its start. The order is
  style only: a function may call a function declared later.
- A constant is `NAME = expr` or `NAME: Type = expr` at the top level. The name
  is capitals, digits and `_`, at least two characters, starting with a capital
  (`MAX_DEPTH`); another spelling is `PARSE-CONSTANT-NAME`, and `IO`, `JSON`,
  `TCP`, `TLS` are reserved. Constants follow each other with no blank line,
  also with `##` docs or `export`; a blank line is still needed before a
  `struct`, `enum` or `def`. The value starts on the line of the `=`. `NAME:
  Type = expr` gives `[]`, `{}` and `Set.new([])` their type.
- A constant is read as `NAME`, in the file that declares it or by a named
  import. It is a value, so `NAME.size`, `NAME.get(k, 0)`, `NAME[i]`, `NAME.each
  do |x| ... end`, `NAME.field` and `"#{NAME}"` work. It never changes: `NAME =
  1` inside a function is `PARSE-INVALID-ASSIGNMENT-TARGET`, and a local can
  never shadow it (locals are lowercase). A constant may read another one,
  before or after it in the file; a loop is `CHECK-CONSTANT-CYCLE` (the help
  lists `A -> B -> A`).
- What a constant may hold: literals, string interpolation, lists, maps,
  `Set.new`, ranges, struct and enum values, `ok`/`error`, operators, field
  access, indexing, other constants, and builtins whose row has no effects
  (`List.map`, `reduce`, `Map.put`, `Set.new`...), with blocks passed to them.
  Not allowed (`CHECK-CONSTANT-EXPRESSION`, at the form): a call of a `def`,
  `&name`, a block that is not an argument of a builtin, `while`, and a builtin
  with effects (`puts`, `IO.*`, `File.*`, `Time.*`, `Random.*`, `Task.*`,
  `Channel.*`...). Every expression inside needs a data type
  (`CHECK-CONSTANT-TYPE` for a `Channel`, `Task`, `Fn`, handle or `Void`).
- A scalar literal constant (`SIZE = 4`, `-1`, `"x"`, `true`, `nil`) is part of
  the bytecode and free to read; every other constant is built once, in
  dependency order, before `main` starts, and only if `main` can reach a
  function that reads it. An error in an initializer (`BAD = [1][5]`) stops the
  program before `main` with the constant in the stack trace.
- The root file needs exactly one `def main() -> Void` with no parameters. Only
  that entrypoint runs.
- Blocks end with `end`; indentation is for reading only. `#` starts a comment
  to the end of the line.
- A newline ends a statement. Inside `(...)`, `[...]`, and `{...}` an expression
  may span lines, and a trailing comma is allowed. To split a long expression,
  wrap it in parentheses.
- A line that starts with `.name` continues the line before it, so a method
  chain spans lines with no parentheses (also after a `do ... end` block). A
  `#` comment may end a line or sit alone between two steps; a blank line, a
  `##` line, `..`, `...` and `|>` at the start of a line do not continue, and
  neither does a dot after the head of an `if`, `while`, `case` or `for`
  (`PARSE-UNEXPECTED-TOKEN`).

  ```ruby
  lines = File.foreach(path, 65536, 1000)
    .drop(1)                          # header
    .map do |line| parse(line) end
    .filter(&big?)
  ```
- Reserved words: `def struct enum case do import export end if elsif else while
  for in return try true false nil and or not`. `with` is not reserved, but
  `value.with(...)` is always the struct update.
- Extra blank or comment lines between statements are ignored.
- `##` lines are doc comments. A `##` block on the lines directly above a `def`,
  `struct`, `enum`, field or variant documents it (Markdown text); the first
  block of a file, followed by a blank line, documents the module. A `##` after
  code on the same line is a plain comment. Any other `##` block is
  `PARSE-DETACHED-DOC`, and a doc block does not count as the blank line between
  declarations.
- A module function with no arguments may drop its parentheses, builtin or
  through an import alias (`IO.gets!`, `IO.eof?`, `Util.reset`). `f =
  Util.helper` is a call; `&Util.helper` is the function value.
- `--max-steps N` bounds execution to N expression or statement entries across
  all tasks (`RUNTIME-STEP-LIMIT`); it is not an I/O timeout.
- `agentica compile FILE.agc -o OUT.agcb` writes the bytecode. `agentica run
  [FLAGS] -- OUT.agcb [ARGS...]` runs it on the VM with `--max-steps`, `--seed`,
  `--flush-timeout`, `--schedulers N`, `--allow-run`, `--source-root DIR`,
  `--ai` or `--json` before the `--`; the words after the file are the
  program's. `run` is read only as the first word. The bytecode runs only on the
  same Agentica version. `agentica run --version` also lists the libraries.
  `--schedulers N` (1 to 1024, or `AGENTICA_SCHEDULERS`) is checked, but the VM
  runs one scheduler, so N above 1 exits 2.

## Types

- **Type:** `Int`
  - **Notes:** signed 64-bit; overflow is a runtime error

- **Type:** `Float`
  - **Notes:** IEEE 754 double

- **Type:** `Bool`
  - **Notes:** `true` / `false` only

- **Type:** `String`
  - **Notes:** Unicode text

- **Type:** `Nil`
  - **Notes:** the single data value `nil`

- **Type:** `Void`
  - **Notes:** completion without a usable value; no literal

- **Type:** `Process`
  - **Notes:** opaque child process; inspect prints `<Process>`

- **Type:** `Lazy[T]`
  - **Notes:** an immutable recipe of steps that a terminal runs; no `==`, no
    `to_s`; inspect prints `<Lazy>` (`references/lazy.md`)

- **Type:** `List[T]`
  - **Notes:** homogeneous, immutable, indexed from 0

- **Type:** `Map[K, V]`
  - **Notes:** homogeneous, immutable; `K` is `Int` or `String`; keeps insertion
    order

- **Type:** `Set[T]`
  - **Notes:** distinct values, immutable; `T` is `Int` or `String`
    (`CHECK-SET-ELEMENT-TYPE` otherwise); keeps first-insertion order; prints as
    `Set[1, 2]`; no `==`, not JSON-encodable

- **Type:** `Result[T]`
  - **Notes:** `ok(value)` or `error(message)`; the error is always String;
    exactly one type argument

- **Type:** `Range`
  - **Notes:** `a..b` (includes `b`) or `a...b` (excludes it) over `Int`; prints
    as `1..5`

- **Type:** `Json`
  - **Notes:** opaque JSON value; use `JSON` functions to access it

- **Type:** `Fn[A, ..., R]`
  - **Notes:** function value (a block or `&name`); last type is the return;
    `Fn[Void]` takes no arguments

- **Type:** `Task[R]`
  - **Notes:** opaque lightweight task; exactly one result type

- **Type:** `Await[T]`
  - **Notes:** builtin enum from `Task.await(task, timeout_ms)`:
    `Await.Done(value)` or `Await.TimedOut`; reserved name; see `tasks.md`

- **Type:** `Channel[T]`
  - **Notes:** opaque bounded queue between tasks (VM only); see `tasks.md`

- **Type:** network handles
  - **Notes:** opaque `Socket`, `Listener`, `HttpClient`, `HttpServer`

- **Type:** `LogLevel`
  - **Notes:** builtin enum of `std/logger`: `LogLevel.Debug`, `Info`,
    `Warning`, `Error`; reserved name; see `logger.md`

- **Type:** builtin records
  - **Notes:** `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions`,
    `HttpServerOptions`, `FileInfo`, `ProcessOutput`, `LogEvent`

- **Type:** `Name`
  - **Notes:** a struct you declare; fields are typed and immutable

A simple alias is `type Names = List[String]`; it can name any type or another
alias and is transparent in all type positions. `export type Names = ...` makes
it available to importing modules, by module alias or by name. It adds no
runtime type and cannot be constructed or used as an enum pattern. Cycles are
`CHECK-TYPE-ALIAS-CYCLE`. Errors in expanded types point to the alias use.
Expansions stop at 1,000 type references with `CHECK-TOO-DEEP`.

A generic alias, `type Matrix[T] = List[List[T]]`, is pure substitution:
`Matrix[Int]` is exactly `List[List[Int]]`. Parameters are type names that
neither repeat nor take a reserved name (`CHECK-REDEFINED-NAME`) and may go
unused. A use needs one argument per parameter (`Matrix` or
`Matrix[Int, Int]` is `CHECK-UNKNOWN-TYPE`); arguments are never inferred.
Aliases may use other aliases (`type Grid = Matrix[Float]`), also through
imports (`S.Matrix[Int]`, `import {Matrix} from "m"`). A parameter may be a
`Map` key in the target; `Index[Float]` fails at the use with
`CHECK-MAP-KEY-TYPE`.

`Option[T]` is not builtin; declare it as an enum if you need it. Type names
start with an uppercase letter. Variable, function, and field names start with a
lowercase letter or `_`.

## Void

`Void` has no literal or usable payload. It is allowed as a function return, the
final type of `Fn`, or the completion type of `Result` and `Task`. Bare Void
variables, parameters, fields, List elements, and Map values are
`CHECK-VOID-TYPE`; wrappers such as `List[Result[Void]]` are valid.

A Void call may be a statement, or be forwarded from a Void function with
`return another_void_call()`. Assignment, argument passing, construction,
operators, and inspection of a bare completion fail with `CHECK-VOID-VALUE`. The
same holds for `Result.unwrap!(Result[Void])`, `Task.await(Task[Void])`, and a
successful `try` on `Result[Void]`.

`ok()` infers `Result[Void]` and prints `ok()`; `ok(nil)` is `Result[Nil]` and
prints `ok(nil)`. A `Result[Void]` function returns `ok()` or `error(message)`
explicitly; `try` still needs a Result-returning function. `Result.unwrap_or`
needs a data fallback and cannot operate on `Result[Void]`.

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

- Leave a blank line after the `end` of each `def`, `struct`, and `enum` before
  the next declaration (`PARSE-MISSING-BLANK-LINE`).
- Every parameter and the return type need an annotation.
- Structs, enums, and functions are top level only. An enum's type parameters
  apply only to its payloads; there are no generic functions or structs, no user
  methods, no nested functions, no keyword arguments, and no overloading.
  Closures are blocks.
- A parameter may end with a default value: `def connect(host: String =
  "localhost", port: Int = 8080, tags: List[String] = [])`. The call may leave
  out any trailing parameters with a default, and fills the others from the
  left: `connect("db")`, `connect("db", 5432)`.
- A default is a constant: an Int, Float or String literal (a minus sign before
  a number is fine, `#{...}` in a string is not), `true`, `false`, `nil`, `[]`,
  `{}`, or an enum variant without a payload (`Level.Info`, `LogLevel.Info`,
  `Models.Level.Info`). `[]` and `{}` take the parameter type and are built
  again at each call. A call, a name, `&name`, a struct, a variant with a
  payload or any other expression is `CHECK-DEFAULT-VALUE`; a default of the
  wrong type is `CHECK-TYPE-MISMATCH` at the default.
- After a parameter with a default, every parameter needs a default
  (`CHECK-DEFAULT-ORDER` at the first that has none), except a last `Fn`
  parameter, which the block or the last argument always fills: with `def
  each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void])`,
  `each_line("a.txt") do |l| ... end` and `each_line("a.txt", 50, &show)` are
  both calls, and `each_line("a.txt", 50)` gives `50` to `f`
  (`CHECK-TYPE-MISMATCH`).
- A call takes from the number of parameters without a default to all of them
  (`CHECK-ARITY` otherwise). A call through an import alias leaves out defaults
  too, and `x = Util.connect` with no parentheses is valid when every parameter
  of `connect` has a default. A function value takes every argument: `&join` is
  `Fn[List[String], String, String]`, and `.call` needs both. `main` and blocks
  take no defaults.
- Source nesting (parentheses, calls, blocks, `if`, types) may go 1000 levels
  deep at most, and each operator of a chain or `.` suffix counts a level too
  (`PARSE-TOO-DEEP`; a chain of 1,000 `+` already fails). The tree of
  expressions and statements may be 1000 levels deep at most (`CHECK-TOO-DEEP`;
  a chain is as deep as it is long, and a chain nested in another can pass the
  parser and fail here).
- Functions may be called before they are declared, and may be recursive. Nested
  calls go 10000 deep at most (`RUNTIME-STACK-OVERFLOW`); tail calls do not
  count toward that depth. Only `return f(...)` whose value is directly a call
  to a user function is a tail call: `return 1 + f(n - 1)` (the call inside a
  larger expression) and calls to builtins are not.
- So recursion over a big list or a big count is written in tail form with an
  accumulator (and an index for a list), or uses `for`, `map`, `filter` or
  `each`. `return count(n - 1, acc + 1)` runs for 1,000,000 calls; `return 1 +
  count(n - 1)` fails with `RUNTIME-STACK-OVERFLOW` at that size.
- Build a list with `xs = xs.push(x)` in a loop. `push` is cheap because lists
  are persistent vectors, so there is no need for the prepend-then-reverse habit
  of Elixir or Lisp.
- A non-Void function must `return` on every path; a loop does not count, and
  the last expression is not returned implicitly. `return` alone, or reaching
  the end, completes a Void function. A `Nil` function returns `nil` explicitly.

## Statements

- The first assignment to a name creates it in the current block. Later
  assignments change its value, never its type. An annotation is allowed only on
  creation (`total: Float = 0.5`).
- `_` binds nothing: `_ = f()` drops a result, and `_` can be a `for` variable,
  a block or function parameter, or a pattern slot, repeated freely. Reading
  `_` is `CHECK-UNKNOWN-NAME`; `_: Int = x` is `PARSE-UNEXPECTED-TOKEN`.
- `x += e`, `-=`, `*=`, `/=`, `%=` mean `x = x op e`; `x` must already exist.
- A name created in a block is not visible after that block's `end`. A new
  variable cannot reuse a name visible in an outer scope (no shadowing).
- `for item in items` binds a read-only variable; it cannot be assigned. `for`
  takes a `List[T]`, a `Set[T]` (in first-insertion order) or a `Range`, and
  runs zero times for an empty or reversed range; a range is never built as a
  list. Write `0...n`, `n.times`, `a.upto(b)`, or `a.downto(b)`; a `for` over a
  range never counts down.
- `case value` ... `end` is a statement. Arms are `pattern -> block`; a short
  arm may hold one simple statement on the arrow line (`1 -> puts("one")`). A
  `do` after the value is allowed but not needed. Bindings are local to their
  arm.
- Patterns are primitive literals, `_`, `ok(...)`, `error(...)`, or qualified
  enum variants with one slot per payload position. A slot is a name, `_`, a
  literal (`-1` too), or another variant pattern, `ok(...)` or `error(...)`, to
  any depth. A name once per arm (`CHECK-SHADOWED-NAME`). A name alone is not a
  top-level pattern. There are no struct or list patterns.
- A guard, `pattern if condition -> ...`, is a Bool (`CHECK-TYPE-MISMATCH`) that
  sees the names of its own arm; if false, `case` goes on with the next arm.
  Keep the guard on the line of the pattern. A later arm may repeat a pattern
  that an earlier guarded arm used. `_ if c ->` is allowed, and it is not a
  catch-all: an unguarded `_` must still be last.
- An arm covers its variant only without a guard and with names or `_` in every
  slot. An arm with a guard, a literal or a nested variant may fail, so `case`
  on `ok(Option.Some(n))` also needs `ok(_)`. An arm is unreachable when an
  earlier arm of that kind already covers its variant, or after an unguarded
  `_`.
- Enum cases cover every variant or use `_`. A non-enum case, including `Bool`
  and `Nil`, requires a final top-level `_`. Duplicate or unreachable arms are
  checker errors.
- `if` and `while` conditions must be `Bool`. There is no truthiness.
- `break` leaves the innermost `while` or `for`; `next` skips to its next
  iteration. Each stands alone on its line. They cannot cross a block or
  function (`CHECK-LOOP-CONTROL`). Inside a block, `return` leaves the block.
- Assignment is a statement, not an expression. There is no `x[i] = v`, `x.f =
  v`, or `continue`.

## Expressions

- Literals: `42`, `3.14`, `1_000` (a `_` between digits is only visual; a
  trailing, double or dot-side `_` is `LEX-INVALID-NUMBER`), `"text"` (escapes
  `\" \\ \# \n \r \t`), `true`, `false`, `nil`. A minus sign is an operator, not
  part of the literal.
- Interpolation: `"total: #{n + 1}"` is a `String`. Strings go in as is, `Json`
  as its JSON text, other data values in their `IO.inspect` form. Keep the
  expression on one line; `\#{` is literal text. `case` patterns and `import`
  paths take plain strings only, not a heredoc.
- Heredocs: `<<~NAME`, the text on the next lines, then a line with only `NAME`
  (capitals, digits, `_`; `<<NAME`, `<<-NAME`, `<<~'NAME'` and `<<~name` are
  `LEX-UNEXPECTED-CHAR`). The smallest indentation among the lines that have
  text is removed from every line, a line of only spaces becomes empty, and
  every line, the last too, ends with `\n`: `<<~T`, `  a`, `    b`, `T` is `"a\n
  b\n"`. Escapes and `#{...}` are those of a string (the expression ends on its
  line); indentation goes before them, so an interpolated value is never
  re-indented. The rest of the opener line is code (`puts(<<~T)`, `<<~T.length`,
  `f(<<~A, <<~B)`, the second body after the first end line); inside `(...)` the
  call goes on after the end line. It needs two lines of text or more, else
  `LEX-HEREDOC-ONE-LINE` (write `"text\n"`); a tab in the indentation is
  `LEX-HEREDOC-INDENT`; no end line is `LEX-UNTERMINATED-HEREDOC`. `xs << x` is
  not Agentica: `xs = xs.push(x)`.
- Lists `[1, 2, 3]`; maps `{"a": 1, "b": 2}`. A repeated key keeps the last
  value at its first position, and `Map.put` on an existing key also keeps that
  position.
- `[]`, `{}` and `Set.new([])` need a known type (annotation, parameter, field,
  or function result): `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`,
  `CHECK-EMPTY-SET-TYPE`. A non-empty list needs one element type.
- Struct construction uses every field exactly once, named, in any order:
  `User(name: "Ana", age: 25)`.
- Struct update `user.with(age: 31)` is a copy with the named fields changed;
  `user` is unchanged. At least one field, each named once and only by name
  (`user.with()` and `user.with(31)` are `PARSE-UNEXPECTED-TOKEN`), with a value
  of the field's type (`[]` and `{}` take it): `CHECK-UNKNOWN-FIELD`,
  `CHECK-DUPLICATE-FIELD`, `CHECK-TYPE-MISMATCH`. The receiver runs first, then
  the values left to right, and every value sees the old struct (`p.with(a: p.b,
  b: p.a)` swaps). It nests and chains: `a.with(address: a.address.with(city:
  "Lima"))`. A bare `user.with(...)` is `CHECK-UNUSED-VALUE`. On a value that is
  not a struct it is `CHECK-UNKNOWN-METHOD`. A struct from another module can be
  updated only when its module exports it and you import that module, by an
  alias or by names (`CHECK-IMPORT-NAME`, as for constructing it). For a state
  that moves through a self-calling function, `return step(s.with(pos: s.pos +
  1))` is a tail call.
- Enum variants are qualified by their type. Payload variants take positional
  arguments (`Option.Some("hi")`); nullary variants take `Option.None` or
  `Option.None()`. Generic arguments come from payloads and expected types; a
  nullary generic variant needs expected-type context.
- Field access `user.name`; index `items[0]` and `stock["apple"]`. Strings
  cannot be indexed. List indexing takes O(log32 n) time (at most four steps for
  a million items); `for` visits the items in order.
- `&name` references a declared top-level function without capturing locals: `f:
  Fn[Int, Int] = &double`, then `f.call(21)`. A block is also a function value
  and captures locals. Function values can be stored in containers, fields,
  parameters, and returns; signatures must match exactly. Bare function names
  are not values. No standalone lambdas, equality, or JSON encoding; inspect
  prints `<Fn>`.

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

- `+ - * /` take two numbers of the same type; there is no implicit conversion.
  `+` also joins two Strings.
- `/` on Int truncates toward zero. `%` takes two Ints. A zero divisor is a
  runtime error, also for Float.
- `< <= > >=` take two numbers of the same type. Comparisons do not chain.
- `==` and `!=` take two values of the same primitive type (Int, Float, Bool,
  String, Nil), or two ranges. Lists, maps, sets, structs, Results, Json, and Fn
  values cannot be compared (two sets are equal when `a.subset?(b) and
  b.subset?(a)`).
- `&&`, `||`, `!` take Bool and short-circuit; `and`, `or`, `not` are the same
  operators. `!` binds tightly, so write `!(a >= b)`. A `!` right after a name
  is part of the name (`read!`).
- Operands are evaluated left to right.
- `x |> f(a)` means `f(x, a)`. The right side must be a call with parentheses
  (`f(a)`, `Alias.f(a)`), optionally after `try`; pipes group to the left (`x |>
  f() |> g()` is `g(f(x))`). A builtin with a method form is written with `.`;
  see `PARSE-PIPE-TARGET` and `CHECK-PIPE-METHOD` in `diagnostics.md`. A chain
  over several lines goes in parentheses, one step per line (a leading `|>` does
  not continue a line, unlike a leading `.name`). Prefer it to
  reassigning the same name in a row:

  ```ruby
  # not: out = header(v)  out = add(out, a)  out = add_all(out, b)
  out = (
    header(v)
    |> add(a)
    |> add_all(b)
  )
  ```

## Blocks and closures

A block is a function written at the call site as the last argument: `xs.map do
|x| x * 2 end`, `run(5) do |n| n + 1 end`.

- Write `do |a, b| ... end` or `do ... end` after the call's `)`, or after a
  method name with no parentheses (`xs.each do`). A user function needs
  parentheses (`run(5) do ... end`); a function through an import alias may drop
  them (`Util.start do ... end`). The called function's last parameter must be a
  `Fn` (`CHECK-BLOCK-TARGET`). Never `do || ... end` or `{ |x| ... }`.
- Parameter types come from the call; annotate when there is no context: `do |x:
  Int| ... end` (`CHECK-BLOCK-TYPE` otherwise).
- The last expression is the block's value; `return value` leaves only the
  block. A non-Void block must give a value on every path. `try` in a block
  needs the block to return a Result known from the call (not in `map` or
  `sort_by`), and it ends with `ok(...)`. The block of `Task.map` gives a
  `Result[R]` with `R` taken from the expected type or from the body, and `try`
  works in it.
- `case`, `while`, and `for` headers may end with an optional `do` (`while !done
  do`, `for x in xs do`); that `do` is never a block. To put a call with a block
  in such a header, wrap it: `case (xs.map do |x| x end) do`.
- Blocks capture values when created; later outer changes do not affect them. A
  block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`); build the
  value with `map`, `reduce`, or a `for` loop. Block parameters cannot reuse
  visible names.
- A block is a `Fn[...]` value: return it, store it, pass it to `Task.spawn`, or
  make a BDD step with `BDD.step("pattern") do |ctx, args| ... end`.
- `List.each` runs a block per element; `List.any?` and `List.all?` stop at the
  first deciding element.

## Result and try

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
```

- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload
  against T, even for `ok([])` or `ok({})`.
- `error("bad")` needs an expected Result type from an annotation, an existing
  binding, a return, an argument, a field, or a typed container element. `r =
  error("bad")` alone is `CHECK-RESULT-TYPE`.
- `try` evaluates its Result operand once: success gives the payload; an error
  returns from the current function. Only a Result-returning function may use
  it. The operand and the function's success type may differ. `try` binds like
  unary `not`; use parentheses for a larger operand. Success paths still need
  explicit returns. The expected type of a `try` supplies `Result[T]` to its
  operand; the function's return type alone does not infer that payload.
- `Result.unwrap!` halts with `RUNTIME-UNWRAP-ERROR` on an error, and passes its
  expected output T into the operand as `Result[T]`. `Result.unwrap_or` uses the
  expected T or infers it from the default, and evaluates both arguments, left
  to right, even on success.
- `Result.ok?` and `Result.message` need a known Result type; they cannot infer
  a bare error's payload. `Result.message` is `""` for a success.
- `ok(false)` and `ok(nil)` are successes. Results nest and may hold lists,
  maps, and structs; they have no equality, fields, or indexing.
- Lists and maps infer their type from the first element: `[ok(1),
  error("bad")]` infers, the reverse order needs an annotation.
- Non-bang conversions (`String.to_int`) use the same syntax and 64-bit bounds
  as the bang forms, but invalid text returns an error. Unrelated runtime errors
  are not converted to Results. `IO.gets` returns a line without LF, CR, or
  CRLF; a blank line is `ok("")`, not end of input.
- `Result.Ok(x)` and `Result.Err(m)` are the same as `ok(x)` and `error(m)`, as
  values and as `case` patterns. `Result.Ok(_)` discards a payload, including
  for `Result[Void]`.

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

These are rejected with a `help` line that names the Agentica form: `let x = 5`,
`match x`, `when 1`, `if x then`, `elif`, `fn(x: Int)`, `lambda do`, `len(x)`,
`Hash.new`, `break if x`, `loop do`, `puts(x) if ok`, `;`, and `while x {` ...
`}`.
