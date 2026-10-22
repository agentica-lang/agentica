# Core language

Read this for the exact rule behind a checker error or a core question that
SKILL.md does not answer. Builtin methods and `to_s` are in `builtins.md`.

## Program shape

- A file has top-level `def`, `struct`, `enum`, type alias, `import` and
  constant declarations; no statement runs at top level. `export` may prefix a
  function, struct, enum, alias or constant.
- Order is style only (a function may call one declared later), but keep it:
  module doc and `import`s, constants, `struct`, `enum` and aliases (exported or
  not, any order), `export def`, then private `def`. The first declaration out
  of place is `CHECK-DECL-ORDER`, at its start.
- An `extern "LIB"` block of C signatures declares native functions, which count
  as `def`s (`native.md`).
- A constant is `NAME = expr` or `NAME: Type = expr`. The name is capitals,
  digits and `_`, at least two characters, starting with a capital
  (`MAX_DEPTH`); else `PARSE-CONSTANT-NAME`. `IO`, `JSON`, `TCP`, `TLS` are
  reserved. Constants need no blank line between them (`##` docs and `export`
  are fine); a blank line still precedes a `struct`, `enum` or `def`. The value
  starts on the `=` line. `NAME: Type = expr` types `[]`, `{}` and
  `Set.new([])`.
- A constant is read as `NAME`, in its file or through a named import, and is a
  value: `NAME.size`, `NAME.get(k, 0)`, `NAME[i]`, `NAME.each do ... end`,
  `NAME.field`, `"#{NAME}"`. It never changes: `NAME = 1` in a function is
  `PARSE-INVALID-ASSIGNMENT-TARGET`, and a local cannot shadow it. A constant
  may read another in either order; a loop is `CHECK-CONSTANT-CYCLE` (the help
  lists `A -> B -> A`).
- Allowed in a constant: literals, interpolation, lists, maps, `Set.new`,
  ranges, struct and enum values, `ok`/`error`, operators, field access,
  indexing, other constants, and builtins with no effects (`List.map`, `reduce`,
  `Map.put`, `Set.new`...) with blocks. Not allowed
  (`CHECK-CONSTANT-EXPRESSION`, at the form): a `def` call, `&name`, a block
  outside a builtin's argument, `while`, and effectful builtins (`puts`, `IO.*`,
  `File.*`, `Time.*`, `Random.*`, `Task.*`, `Channel.*`...). Each expression
  needs a data type (`CHECK-CONSTANT-TYPE` for `Channel`, `Task`, `Fn`, handles,
  `Void`).
- Scalar literal constants (`SIZE = 4`, `-1`, `"x"`, `true`, `nil`) live in the
  bytecode and cost nothing to read. Other constants are built once, in
  dependency order, before `main`, and only if `main` can reach a reader. An
  initializer error (`BAD = [1][5]`) stops the program before `main`, with the
  constant in the stack trace.
- The root file needs exactly one `def main() -> Void` with no parameters to run
  or compile; `agentica check` accepts a file without one. Only `main` runs.
- Blocks end with `end`; indentation is for reading only. `#` starts a comment
  to the end of the line.
- A newline ends a statement. Inside `(...)`, `[...]` and `{...}` an expression
  may span lines, with trailing commas allowed. Wrap a long expression in
  parentheses to split it.
- A line starting with `.name` continues the line before it, also after a `do
  ... end` block; a `#` comment may end a line or sit between steps. These do
  not continue a line: a blank line, a `##` line, a line starting with `..`,
  `...` or `|>`, and a dot after the head of an `if`, `while`, `case` or `for`
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
- `##` lines are Markdown doc comments. A `##` block directly above a `def`,
  `struct`, `enum`, field or variant documents it; the first block of a file,
  followed by a blank line, documents the module. A `##` after code is a plain
  comment. Any other `##` block is `PARSE-DETACHED-DOC`, and a doc block does
  not count as the blank line between declarations.
- A no-argument module function may drop its parentheses, builtin or through an
  import alias (`IO.gets!`, `IO.eof?`, `Util.reset`). `f = Util.helper` calls
  it; `&Util.helper` is the function value.
- `--max-steps N` bounds expression and statement entries across all tasks
  (`RUNTIME-STEP-LIMIT`); it is not an I/O timeout.
- `agentica compile FILE.agc -o OUT.agcb` writes bytecode; `agentica run [FLAGS]
  -- OUT.agcb [ARGS...]` runs it. Flags go before `--`: `--max-steps`, `--seed`,
  `--flush-timeout`, `--schedulers N`, the `--deny-*` flags, `--sandbox`,
  `--source-root DIR`, `--ai`, `--json`. `run` is read only as the first word;
  the words after the file are the program's. Bytecode runs only on the same
  Agentica version. `agentica run --version` also lists the libraries.
- Scheduler threads (`--schedulers N`): see `tasks.md`.

## Types

- `Int`: signed 64-bit; overflow is a runtime error
- `Float`: IEEE 754 double
- `Bool`: `true` / `false` only
- `String`: Unicode text
- `Nil`: the single data value `nil`
- `Void`: completion without a usable value; no literal
- `Process`: opaque child process; inspect prints `<Process>`
- `Lazy[T]`: an immutable recipe that a terminal runs; no `==`, no `to_s`;
  inspect prints `<Lazy>` (`lazy.md`)
- `List[T]`: homogeneous, immutable, indexed from 0
- `Map[K, V]`: homogeneous, immutable; `K` is `Int` or `String`; keeps insertion
  order
- `Set[T]`: distinct, immutable; `T` is `Int` or `String`
  (`CHECK-SET-ELEMENT-TYPE`); keeps first-insertion order; prints `Set[1, 2]`;
  no `==`, not JSON-encodable
- `Result[T]`: `ok(value)` or `error(message)`; the error is always String;
  exactly one type argument
- `Range`: `a..b` (includes `b`) or `a...b` (excludes it) over `Int`; prints
  `1..5`
- `Json`: opaque JSON value; use `JSON` functions to access it
- `Fn[A, ..., R]`: a block or `&name`; the last type is the return; `Fn[Void]`
  takes no arguments
- `Task[R]`: opaque lightweight task; exactly one result type
- `Await[T]`: builtin enum from `Task.await(task, timeout_ms)`:
  `Await.Done(value)` or `Await.TimedOut`; reserved; see `tasks.md`
- `Channel[T]`: opaque bounded queue between tasks (VM only); see `tasks.md`
- network handles: opaque `Socket`, `Listener`, `HttpClient`, `HttpServer`
- `LogLevel`: builtin enum of `std/logger`: `Debug`, `Info`, `Warning`, `Error`;
  reserved; see `logger.md`
- builtin records: `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions`,
  `HttpServerOptions`, `FileInfo`, `ProcessOutput`, `LogEvent`
- `Name`: a struct you declare; its fields are typed and immutable

`type Names = List[String]` names any type or alias and is transparent in every
type position. `export type Names = ...` makes it importable by module alias or
by name. It adds no runtime type and cannot be constructed or used as an enum
pattern. Cycles are `CHECK-TYPE-ALIAS-CYCLE`; errors in an expanded type point
to the alias use. Expansions stop at 1,000 type references (`CHECK-TOO-DEEP`).

`type Matrix[T] = List[List[T]]` is pure substitution: `Matrix[Int]` is exactly
`List[List[Int]]`. Its parameters are type names that neither repeat nor take a
reserved name (`CHECK-REDEFINED-NAME`), and may go unused. A use needs one
argument per parameter (`Matrix` or `Matrix[Int, Int]` is `CHECK-UNKNOWN-TYPE`);
arguments are never inferred. Aliases may use aliases (`type Grid =
Matrix[Float]`), also through imports (`S.Matrix[Int]`, `import {Matrix} from
"m"`). A parameter may be a `Map` key in the target: `Index[Float]` fails at the
use with `CHECK-MAP-KEY-TYPE`.

`Option[T]` is not builtin; declare an enum. Type names start uppercase;
variables, functions and fields start lowercase or `_`.

## Void

`Void` has no literal or payload. It is allowed as a function return, as the
last type of `Fn`, and as the completion of `Result` and `Task`. Bare Void
variables, parameters, fields, list elements and map values are
`CHECK-VOID-TYPE`; `List[Result[Void]]` is valid. A Void call may be a
statement, or be forwarded with `return another_void_call()`. Assigning,
passing, constructing, operating on or inspecting a bare completion is
`CHECK-VOID-VALUE`, as is `Result.unwrap!(Result[Void])`,
`Task.await(Task[Void])` and a successful `try` on `Result[Void]`.

`ok()` infers `Result[Void]` and prints `ok()`; `ok(nil)` is `Result[Nil]` and
prints `ok(nil)`. A `Result[Void]` function returns `ok()` or `error(message)`
explicitly; `try` still needs a Result-returning function. `Result.unwrap_or`
needs a data fallback, so it cannot take `Result[Void]`.

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

- Leave a blank line after the `end` of each `def`, `struct` and `enum`
  (`PARSE-MISSING-BLANK-LINE`). Every parameter and the return type need an
  annotation.
- Structs, enums and functions are top level only. Only enums and aliases take
  type parameters, and an enum's apply to its payloads. There are no generic
  functions or structs, user methods, nested functions, keyword arguments or
  overloads. Closures are blocks.
- A parameter may have a default: `def connect(host: String = "localhost", port:
  Int = 8080, tags: List[String] = [])`. A call omits trailing defaulted
  parameters and fills the rest from the left: `connect("db")`, `connect("db",
  5432)`.
- A default must be a constant: an Int, Float or String literal (a minus before
  a number is fine; `#{...}` in a string is not), `true`, `false`, `nil`, `[]`,
  `{}`, or a payload-less enum variant (`Level.Info`, `LogLevel.Info`,
  `Models.Level.Info`). `[]` and `{}` take the parameter type and are built
  again at each call. Anything else (a call, a name, `&name`, a struct, a
  variant with a payload) is `CHECK-DEFAULT-VALUE`; a wrong type is
  `CHECK-TYPE-MISMATCH` at the default.
- After a defaulted parameter, every parameter needs a default
  (`CHECK-DEFAULT-ORDER`), except a last `Fn` parameter, which a block or the
  last argument always fills. With `def each_line(path: String, timeout_ms: Int
  = 1000, f: Fn[String, Void])`, `each_line("a.txt") do |l| ... end` and
  `each_line("a.txt", 50, &show)` are both calls, and `each_line("a.txt", 50)`
  gives `50` to `f` (`CHECK-TYPE-MISMATCH`).
- A call takes from the number of non-defaulted parameters up to all of them
  (`CHECK-ARITY`). Calls through an import alias leave defaults out too, and `x
  = Util.connect` is valid when every parameter has a default. A function value
  takes every argument: `&join` is `Fn[List[String], String, String]`, and
  `.call` needs both. `main` and blocks take no defaults.
- Nesting: parentheses, calls, blocks, `if` and types go 1000 levels deep at
  most, and each operator of a chain or `.` suffix counts a level too
  (`PARSE-TOO-DEEP`; a chain of 1,000 `+` already fails). The tree of
  expressions and statements goes 1000 levels deep at most (`CHECK-TOO-DEEP`; a
  chain nested in another can pass the parser and fail here).
- Functions may be called before they are declared, and may recurse. Nested
  calls go 10000 deep at most (`RUNTIME-STACK-OVERFLOW`); tail calls do not
  count toward that depth. Only `return f(...)` whose value is directly a call
  to a user function is a tail call: `return 1 + f(n - 1)` and calls to builtins
  are not. So recurse over big inputs in tail form with an accumulator (and an
  index for a list), or use `for`, `map`, `filter` or `each`: `return count(n -
  1, acc + 1)` runs for 1,000,000 calls, while `return 1 + count(n - 1)` fails
  at that size with `RUNTIME-STACK-OVERFLOW`.
- A non-Void function must `return` on every path. A loop does not count (put a
  `return` after `while true`), and the last expression is not returned
  implicitly. `return`, or reaching the end, completes a Void function. A `Nil`
  function returns `nil` explicitly.

## Statements

- The first assignment creates a name in the current block; later assignments
  change its value, never its type. An annotation is allowed only on creation
  (`total: Float = 0.5`).
- `_` binds nothing: `_ = f()` drops a result, and `_` can be a `for` variable,
  a parameter or a pattern slot, repeated freely. Reading `_` is
  `CHECK-UNKNOWN-NAME`; `_: Int = x` is `PARSE-UNEXPECTED-TOKEN`.
- `x += e` (also `-=`, `*=`, `/=`, `%=`) means `x = x op e`; `x` must exist.
- A name created in a block is not visible after its `end`. A new variable
  cannot reuse a name visible in an outer scope (no shadowing).
- `for item in items` binds a read-only variable. `for` takes a `List[T]`, a
  `Set[T]` (first-insertion order) or a `Range`. A range runs zero times when
  empty or reversed, and is never built as a list. Write `0...n`, `n.times`,
  `a.upto(b)` or `a.downto(b)`; a `for` over a range never counts down.
- `case value` ... `end` is a statement. Arms are `pattern -> block`; a short
  arm may hold one simple statement on the arrow line (`1 -> puts("one")`). A
  `do` after the value is optional. Arm bindings are local to their arm.
- Patterns are primitive literals, `_`, `ok(...)`, `error(...)`, or qualified
  enum variants with one slot per payload. A slot is a name, `_`, a literal
  (`-1` too) or a variant pattern (`ok`/`error` too), to any depth. A name
  appears once per arm (`CHECK-SHADOWED-NAME`). A bare name is not a top-level
  pattern. There are no struct or list patterns.
- A guard, `pattern if condition -> ...`, must be Bool (`CHECK-TYPE-MISMATCH`).
  It sees its own arm's names; when false, `case` tries the next arm. Keep the
  guard on the pattern's line. A later arm may repeat the pattern of an earlier
  guarded arm. `_ if c ->` is allowed but is not a catch-all: an unguarded `_`
  must still be last.
- An arm covers its variant only when unguarded and with names or `_` in every
  slot. A guarded, literal or nested-variant arm may fail, so `case` on
  `ok(Option.Some(n))` also needs `ok(_)`. An arm is unreachable when an earlier
  arm already covers its variant, or when it follows an unguarded `_`.
- Enum cases cover every variant or end with `_`. A non-enum case, including
  `Bool` and `Nil`, needs a final top-level `_`. Duplicate or unreachable arms
  are checker errors.
- `if` and `while` conditions must be `Bool`. There is no truthiness.
- `break` leaves the innermost `while` or `for`; `next` skips to its next
  iteration. Each stands alone on its line, and neither crosses a block or
  function (`CHECK-LOOP-CONTROL`). Inside a block, `return` leaves the block.
- Assignment is a statement, not an expression. There is no `x[i] = v`, `x.f =
  v` or `continue`.

## Expressions

- Literals: `42`, `3.14`, `1_000` (a `_` between digits is only visual; a
  trailing, doubled or dot-adjacent `_` is `LEX-INVALID-NUMBER`), `"text"`
  (escapes `\" \\ \# \n \r \t`), `true`, `false`, `nil`. A minus sign is an
  operator, not part of the literal.
- Interpolation: `"total: #{n + 1}"`. Strings go in as is, `Json` as its JSON
  text, other data in their `IO.inspect` form. Keep the expression on one line;
  `\#{` is literal text. `case` patterns and `import` paths take plain strings
  only, not a heredoc.
- Heredocs: `<<~NAME`, the text lines, then a line with only `NAME` (capitals,
  digits, `_`; `<<NAME`, `<<-NAME`, `<<~'NAME'` and `<<~name` are
  `LEX-UNEXPECTED-CHAR`). The smallest indentation among the text lines is
  removed from every line, a space-only line becomes empty, and every line, the
  last too, ends with `\n`: `<<~T`, ` a`, ` b`, `T` is `"a\n b\n"`. Escapes and
  `#{...}` work as in a string; indentation is removed first, so an interpolated
  value is never re-indented. The rest of the opener line is code (`puts(<<~T)`,
  `<<~T.length`, `f(<<~A, <<~B)`); inside `(...)` the call goes on after the end
  line. It needs two text lines or more (else `LEX-HEREDOC-ONE-LINE`; write
  `"text\n"`); a tab in the indentation is `LEX-HEREDOC-INDENT`; no end line is
  `LEX-UNTERMINATED-HEREDOC`. `xs << x` is not Agentica: `xs = xs.push(x)`.
- Lists `[1, 2, 3]`; maps `{"a": 1, "b": 2}`. A repeated key keeps the last
  value at its first position, and `Map.put` on an existing key keeps that
  position.
- `[]`, `{}` and `Set.new([])` need a known type from an annotation, parameter,
  field or function result (`CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`,
  `CHECK-EMPTY-SET-TYPE`). A non-empty list needs one element type.
- Struct construction names every field exactly once, in any order: `User(name:
  "Ana", age: 25)`.
- Update: `user.with(age: 31)` copies the struct with named fields changed. It
  takes at least one field, each named once and only by name (`user.with()` and
  `user.with(31)` are `PARSE-UNEXPECTED-TOKEN`), each with a value of the
  field's type; `[]` and `{}` take it (`CHECK-UNKNOWN-FIELD`,
  `CHECK-DUPLICATE-FIELD`, `CHECK-TYPE-MISMATCH`). The receiver runs first, then
  the values left to right, and every value sees the old struct (`p.with(a: p.b,
  b: p.a)` swaps). It nests and chains: `a.with(address: a.address.with(city:
  "Lima"))`. A bare `user.with(...)` is `CHECK-UNUSED-VALUE`; on a non-struct it
  is `CHECK-UNKNOWN-METHOD`. A struct from another module updates only when that
  module exports it and you import it, by alias or names (`CHECK-IMPORT-NAME`).
  For a state moved through a self-calling function, `return step(s.with(pos:
  s.pos + 1))` is a tail call.
- Enum variants are qualified by their type. Payload variants take positional
  arguments (`Option.Some("hi")`); nullary ones take `Option.None` or
  `Option.None()`. Generic arguments come from payloads and expected types, so a
  nullary generic variant needs an expected type.
- Field access `user.name`; index `items[0]` and `stock["apple"]`. Strings
  cannot be indexed. List indexing takes O(log32 n) time (at most four steps for
  a million items); `for` visits items in order.
- `&name` references a top-level function without capturing locals: `f: Fn[Int,
  Int] = &double`, then `f.call(21)`. A block is also a function value, and it
  captures locals. Function values can be stored in containers, fields,
  parameters and returns; their signatures must match exactly. Bare function
  names are not values. There are no standalone lambdas, equality or JSON
  encoding; inspect prints `<Fn>`.

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

- `+ - * /` take two numbers of one type, with no implicit conversion; `+` also
  joins two Strings.
- `/` on Int truncates toward zero; `%` takes two Ints. A zero divisor is a
  runtime error, also for Float.
- `< <= > >=` take two numbers of one type. Comparisons do not chain: write `a <
  b and b < c`.
- `==` and `!=` take two values of one primitive type (Int, Float, Bool, String,
  Nil), or two ranges. Lists, maps, sets, structs, Results, Json and Fn values
  cannot be compared (two sets are equal when `a.subset?(b) and b.subset?(a)`).
- `&&`, `||`, `!` take Bool and short-circuit; `and`, `or`, `not` are the same
  operators. `!` binds tightly, so write `!(a >= b)`. A `!` right after a name
  is part of the name (`read!`).
- Operands are evaluated left to right.
- `x |> f(a)` means `f(x, a)`. The right side is a call with parentheses
  (`f(a)`, `Alias.f(a)`), optionally after `try`; pipes group to the left (`x |>
  f() |> g()` is `g(f(x))`). A builtin with a method form is written with `.`
  (see `PARSE-PIPE-TARGET` and `CHECK-PIPE-METHOD` in `diagnostics.md`). A chain
  over several lines goes in parentheses, one step per line; a leading `|>` does
  not continue a line, unlike a leading `.name`. Prefer it to reassigning one
  name in a row:

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

- `do |a, b| ... end` or `do ... end` follows the call's `)`, or a method name
  with no parentheses (`xs.each do`). A user function needs parentheses (`run(5)
  do ... end`); a function through an import alias may drop them (`Util.start do
  ... end`). The last parameter must be a `Fn` (`CHECK-BLOCK-TARGET`). Never `do
  || ... end` or `{ |x| ... }`.
- Parameter types come from the call; annotate when there is no context: `do |x:
  Int| ... end` (`CHECK-BLOCK-TYPE` otherwise).
- The last expression is the block's value; `return value` leaves only the
  block. A non-Void block gives a value on every path. `try` in a block needs a
  Result return known from the call (not in `map` or `sort_by`), and the block
  ends with `ok(...)`. The block of `Task.map` gives a `Result[R]`, with `R`
  taken from the expected type or the body, and `try` works there. In a `Lazy`
  method block, `try` always works (`lazy.md`).
- `case`, `while` and `for` headers may end with an optional `do` (`while !done
  do`, `for x in xs do`); that `do` is never a block. To put a call with a block
  in such a header, wrap it: `case (xs.map do |x| x end) do`.
- Blocks capture values when created. A block cannot assign an outer variable
  (`CHECK-CAPTURED-ASSIGNMENT`); build the value with `map`, `reduce` or a `for`
  loop. Block parameters cannot reuse visible names.
- A block is a `Fn[...]` value: return it, store it, pass it to `Task.spawn`, or
  make a BDD step with `BDD.step("pattern") do |ctx, args| ... end`.

## Result and try

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
```

- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload
  against T, even for `ok([])` or `ok({})`.
- `error("bad")` needs an expected Result type from an annotation, an existing
  binding, a return, an argument, a field or a typed container element. `r =
  error("bad")` alone is `CHECK-RESULT-TYPE`.
- `try` evaluates its Result operand once: success gives the payload, and an
  error returns from the current function, which must return a Result. The
  operand and the function's success type may differ. `try` binds like unary
  `not`; use parentheses for a larger operand. Success paths still need explicit
  returns. A `try` supplies `Result[T]` to its operand; the function's return
  type alone does not.
- `Result.unwrap!` halts with `RUNTIME-UNWRAP-ERROR` on an error, and passes its
  expected type into the operand as `Result[T]`. `Result.unwrap_or` uses the
  expected T or the default's type, and evaluates both arguments, left to right,
  even on success.
- `Result.ok?` and `Result.message` need a known Result type; they cannot infer
  a bare error's payload. `Result.message` is `""` for a success.
- `ok(false)` and `ok(nil)` are successes. Results nest and may hold lists, maps
  and structs; they have no equality, fields or indexing.
- Lists and maps infer their type from the first element: `[ok(1),
  error("bad")]` infers, the reverse order needs an annotation.
- Non-bang conversions (`String.to_int`) use the same syntax and 64-bit bounds
  as the bang forms, but invalid text returns an error. Other runtime errors are
  not converted to Results.
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
`Hash.new`, `range(n)`, `break if x`, `loop do`, `puts(x) if ok`, `;`, and
`while x {` ... `}`.
