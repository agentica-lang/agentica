# Core language

The exact rule behind a checker error or a core question. Builtin methods and
`to_s`: `builtins.md`.

## Running

- `agentica FILE.agc ARGS` checks, then runs; `System.args()` returns ARGS (the
  words after the file are the program's). `agentica check FILE.agc` only checks
  (`check --stdin FILE.agc` reads the text from standard input). Exit 0 is
  success, 1 a diagnostic, 2 bad usage or an unreadable file.
- `--ai` prints a diagnostic as compact text, `--json` as one object (the last
  stderr line, after the program's own stderr). Put them before the file.
- `agentica help NAME` prints a builtin's signature (unknown name: exit 2);
  `agentica doc PATH` the exported API of a file or `std/` module.
- `--deny-run`, `--deny-net`, `--deny-fs`, `--deny-env` and `--deny-native` make
  the blocked calls fail with `denied: --deny-X`; `--sandbox` sets all of them,
  for untrusted code. A program can start a process past one flag, so use
  `--sandbox` or add `--deny-run`.
- `--max-steps N` bounds expression and statement entries across all tasks
  (`RUNTIME-STEP-LIMIT`); it is not an I/O timeout.
- `agentica compile FILE.agc -o OUT.agcb` writes bytecode; `agentica run
  [FLAGS] -- OUT.agcb [ARGS...]` runs it (`run` only as the first word), on the
  same Agentica version only. Flags go before `--`: `--max-steps`, `--seed`,
  `--flush-timeout`, `--schedulers N`, the `--deny-*` flags, `--sandbox`,
  `--source-root DIR`, `--ai`, `--json`. `agentica run --version` also lists the
  libraries.
- `agentica F.agc` and `agentica test` keep the compiled program of each root
  file in `_build/bytecode/`, in the folder of the nearest `agentica.toml`
  (else beside F), and read it while F, its imports, `agentica.toml`,
  `agentica.lock` and the places the `pkg/` search looked at are the same (a
  hit has no front-end diagnostics). A folder or entry that is a link, not
  yours, or writable by others is not used (`chmod go-w` a folder you made).
  `--no-cache` skips it for one run; `AGENTICA_BUILD_DIR=DIR` replaces
  `_build/`; an unwritable folder runs without it. `check`, `compile`,
  `--dump*` and `run` never use it.
- Scheduler threads (`--schedulers N`): `tasks.md`.

## Program shape

- Top level holds `def`, `struct`, `enum`, `type` alias, `import` and constants;
  no statement runs there. `export` prefixes a function, struct, enum, alias or
  constant. An `extern "LIB"` block declares native functions, which count as
  `def`s, and resources, which count as types (`native.md`).
- Order is checked: module doc and `import`s, constants, `struct`, `enum`,
  aliases and `extern` resources (any order), `export def`, then private `def`.
  The first declaration out of place is `CHECK-DECL-ORDER`. A function may call
  one declared later.
- A constant is `NAME = expr` or `NAME: Type = expr` (the type also types `[]`,
  `{}` and `Set.new([])`). The name is capitals, digits and `_`, at least two
  characters, capital first (`MAX_DEPTH`), else `PARSE-CONSTANT-NAME`. `IO`,
  `JSON`, `TCP`, `TLS` are reserved. Constants need no blank line between them
  (`##` docs and `export` are fine); a blank line precedes a `struct`, `enum` or
  `def`. The value starts on the `=` line.
- A constant is read as `NAME` in its file or through a named import, and is a
  value (`NAME.size`, `NAME[i]`, `NAME.field`, `"#{NAME}"`) that never changes:
  `NAME = 1` in a function is `PARSE-INVALID-ASSIGNMENT-TARGET`, and a local
  cannot shadow it. Constants may read each other in either order; a loop is
  `CHECK-CONSTANT-CYCLE`.
- Allowed in a constant: literals, interpolation, lists, maps, `Set.new`,
  ranges, struct and enum values, `ok`/`error`, operators, field access,
  indexing, other constants, and builtins with no effects, with blocks
  (`List.map`, `reduce`, `Map.put`). Not allowed (`CHECK-CONSTANT-EXPRESSION`):
  a `def` call, `&name`, a block outside a builtin's argument, `while`,
  effectful builtins (`puts`, `IO.*`, `File.*`, `Time.*`, `Random.*`, `Task.*`,
  `Channel.*`). The value needs a data type (`CHECK-CONSTANT-TYPE` for
  `Channel`, `Task`, `Fn`, handles, `Void`).
- Scalar literal constants (`SIZE = 4`, `"x"`, `true`, `nil`) cost nothing to
  read. Others are built once, in dependency order, before `main`, and only if
  `main` can reach a reader. An initializer error (`BAD = [1][5]`) stops the
  program before `main`.
- The root file needs exactly one `def main() -> Void` with no parameters to run
  or compile (`CHECK-MAIN`); `check` accepts a file without one. Only `main`
  runs.
- Blocks end with `end`; indentation is for reading. `#` starts a comment.
- A newline ends a statement. Inside `(...)`, `[...]` and `{...}` an expression
  may span lines (trailing commas allowed); wrap a long expression in
  parentheses to split it.
- A line starting with `.name` continues the line before it, also after `do ...
  end`; a `#` comment may end a line or sit between steps. These do not continue
  a line: a blank line, a `##` line, a line starting with `..`, `...` or `|>`,
  and a dot after the head of an `if`, `while`, `case` or `for`
  (`PARSE-UNEXPECTED-TOKEN`).

  ```ruby
  lines = File.foreach(path, 65536, 1000)
    .drop(1)                          # header
    .map do |line| parse(line) end
    .select(&big?)
  ```
- Reserved words: `def struct enum case do import export end if elsif else
  while for in return try true false nil and or not`. `value.with(...)` is
  always the struct update.
- `##` lines are Markdown doc comments. A `##` block directly above a `def`,
  `struct`, `enum`, field or variant documents it; the first block of a file,
  followed by a blank line, documents the module. A `##` after code is a plain
  comment. Any other `##` block is `PARSE-DETACHED-DOC`, and a doc block does
  not count as the blank line between declarations.
- A no-argument module function may drop its parentheses, builtin or through an
  import alias (`IO.gets!`, `Util.reset`). `f = Util.helper` calls it;
  `&Util.helper` is the function value.

## Types

- `Int`: signed 64-bit; overflow is a runtime error. `Float`: IEEE 754 double.
  `Bool`: `true` / `false` only. `String`: Unicode text. `Nil`: the value `nil`.
- `Void`: completion without a value; no literal.
- `List[T]`: homogeneous, immutable, indexed from 0. `Map[K, V]`: immutable,
  keeps insertion order, `K` is `Int` or `String`. `Set[T]`: distinct,
  immutable, first-insertion order, `T` is `Int` or `String`
  (`CHECK-SET-ELEMENT-TYPE`), prints `Set[1, 2]`, no `==`, not JSON-encodable.
- `Result[T]`: `ok(value)` or `error(message)` (the message is a String); one
  type argument.
- `Range`: `a..b` (includes `b`) or `a...b` (excludes it) over `Int`; prints
  `1..5`.
- `Json`: opaque; use `JSON` functions. `Fn[A, ..., R]`: a block or `&name`, the
  last type is the return; `Fn[Void]` takes no arguments.
- Opaque, with no constructor or `==`: `Process` (`<Process>`), `Lazy[T]`
  (`lazy.md`), `Task[R]`, `Channel[T]` (`tasks.md`), `Socket`, `Listener`,
  `HttpClient`, `HttpServer`.
- Builtin enums, reserved: `Await[T]` (`Await.Done(value)`, `Await.TimedOut`;
  `tasks.md`) and `LogLevel` (`Debug`, `Info`, `Warning`, `Error`; `logger.md`).
- Builtin records: `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions`,
  `HttpServerOptions`, `FileInfo`, `ProcessOutput`, `LogEvent`. `Name` is a
  struct you declare; its fields are typed and immutable.
- Type names start uppercase; variables, functions and fields start lowercase
  or `_`. `Option[T]` is not builtin; declare an enum.

`type Names = List[String]` names any type and is transparent in every type
position. `export type` makes it importable. It adds no runtime type and cannot
be constructed or used as an enum pattern. Cycles are `CHECK-TYPE-ALIAS-CYCLE`;
errors in an expanded type point to the alias use; expansion stops at 1,000 type
references (`CHECK-TOO-DEEP`).

`type Matrix[T] = List[List[T]]` is pure substitution. Its parameters are type
names that neither repeat nor take a reserved name (`CHECK-REDEFINED-NAME`), and
may go unused. A use needs one argument per parameter (`Matrix` or
`Matrix[Int, Int]` is `CHECK-UNKNOWN-TYPE`); arguments are never inferred.
Aliases may use aliases and imports (`S.Matrix[Int]`, `import {Matrix} from
"m"`). A parameter may be a `Map` key in the target: `Index[Float]` fails at the
use with `CHECK-MAP-KEY-TYPE`.

## Void

`Void` has no literal or payload. It is allowed as a function return, as the
last type of `Fn`, and as the completion of `Result` and `Task`. Bare Void
variables, parameters, fields, list elements and map values are
`CHECK-VOID-TYPE`; `List[Result[Void]]` is valid. A Void call may be a statement
or be forwarded with `return another_void_call()`. Assigning, passing,
constructing, operating on or inspecting a bare completion is `CHECK-VOID-VALUE`
(`v = puts("x")`), as is `r.unwrap!` on a `Result[Void]`,
`Task.await(Task[Void])` and a successful `try` on `Result[Void]`.

`ok()` is `Result[Void]` and prints `ok()`; `ok(nil)` is `Result[Nil]`. A
`Result[Void]` function returns `ok()` or `error(message)` explicitly.
`r.unwrap_or(d)` needs a data fallback, so it cannot take `Result[Void]`.

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

- A blank line follows the `end` of each `def`, `struct` and `enum`
  (`PARSE-MISSING-BLANK-LINE`). Every parameter and the return type need an
  annotation.
- Structs, enums and functions are top level only. Only enums and aliases take
  type parameters. There are no generic functions or structs, user methods,
  nested functions, keyword arguments or overloads. Closures are blocks.
- A parameter may have a default: `def connect(host: String = "localhost", port:
  Int = 8080)`. A call omits trailing defaulted parameters (`connect("db")`).
  The default is a constant: an Int, Float or String literal (a minus before a
  number is fine; `#{...}` is not), `true`, `false`, `nil`, `[]`, `{}` (built
  again at each call, typed by the parameter) or a payload-less enum variant
  (`Level.Info`, or `Models.Level.Info` from another module). Anything else is
  `CHECK-DEFAULT-VALUE`; a wrong type is `CHECK-TYPE-MISMATCH` at the default.
- After a defaulted parameter every parameter needs a default
  (`CHECK-DEFAULT-ORDER`), except a last `Fn` parameter, which a block or the
  last argument always fills: with `def each_line(path: String, timeout_ms: Int
  = 1000, f: Fn[String, Void])`, `each_line("a.txt", 50)` gives `50` to `f`
  (`CHECK-TYPE-MISMATCH`).
- A call takes from the number of non-defaulted parameters up to all of them
  (`CHECK-ARITY`), also through an import alias; `x = Util.connect` is valid
  when every parameter has a default. A function value takes every argument:
  `&join` is `Fn[List[String], String, String]`, and `.call` needs both. `main`
  and blocks take no defaults.
- Nesting goes 1000 levels at most for parentheses, calls, blocks, `if` and
  types, and each operator of a chain or `.` suffix counts a level
  (`PARSE-TOO-DEEP`; 1,000 `+` already fail). The tree of expressions and
  statements is 1000 deep at most (`CHECK-TOO-DEEP`).
- Calls nest 10000 deep at most (`RUNTIME-STACK-OVERFLOW`). Tail calls do not
  count: only `return f(...)` whose value is directly a user-function call
  (`return 1 + f(n - 1)` and builtin calls are not). Recurse over big inputs in
  tail form with an accumulator, or use `for`, `map`, `select`, `each`:
  `return count(n - 1, acc + 1)` runs 1,000,000 calls.
- A non-Void function must `return` on every path (`CHECK-MISSING-RETURN`); a
  loop does not count (put a `return` after `while true`) and the last
  expression is not returned implicitly. A Void function completes at `return`
  or at its end. A `Nil` function returns `nil` explicitly.

## Statements

- The first assignment creates a name in the current block; later ones change
  its value, never its type. An annotation is allowed only on creation
  (`total: Float = 0.5`; else `CHECK-ANNOTATION-ON-EXISTING`).
- `_` binds nothing: `_ = f()` drops a result; it can be a `for` variable, a
  parameter or a pattern slot, repeated freely. Reading `_` is
  `CHECK-UNKNOWN-NAME`; `_: Int = x` is `PARSE-UNEXPECTED-TOKEN`.
- `x += e` (also `-=`, `*=`, `/=`, `%=`) is `x = x op e`; `x` must exist.
- A name created in a block is not visible after its `end`. A new variable
  cannot reuse a visible name (no shadowing: `CHECK-SHADOWED-NAME`).
- `for item in items` binds a read-only variable (`CHECK-IMMUTABLE-ASSIGNMENT`
  on assignment) over a `List[T]`, a `Set[T]` or a `Range`; anything else is
  `CHECK-NOT-A-LIST`. A range runs zero times when empty or reversed and is
  never built as a list. Write `0...n`, `n.times`, `a.upto(b)` or `a.downto(b)`;
  a `for` over a range never counts down.
- `case value` ... `end` is a statement. Arms are `pattern -> block`; a short
  arm may hold one simple statement on the arrow line (`1 -> puts("one")`). A
  `do` after the value is optional. Arm bindings are local to their arm.
- Patterns are primitive literals, `_`, `ok(...)`, `error(...)`, or qualified
  enum variants with one slot per payload. A slot is a name, `_`, a literal
  (`-1` too) or a variant pattern, to any depth. A name appears once per arm
  (`CHECK-SHADOWED-NAME`). A bare name is not a top-level pattern. There are no
  struct or list patterns (`CHECK-PATTERN-TYPE` for a pattern that does not fit
  the value).
- A guard, `pattern if condition -> ...`, must be Bool (`CHECK-TYPE-MISMATCH`),
  sees its arm's names, stays on the pattern's line, and when false `case` tries
  the next arm. A later arm may repeat a guarded arm's pattern. `_ if c ->` is
  not a catch-all.
- Cover: an enum `case` lists every variant or ends with `_`; any other `case`
  (Int, Float, String, `Bool`, `Nil`) ends with a top-level `_`. An arm covers
  its variant only when unguarded with names or `_` in every slot, so guarded,
  literal and nested-variant arms need a closing `ok(_)`, `Shape.Pair(_, _)` or
  `_`. Missing cover is `CHECK-NON-EXHAUSTIVE-CASE`; an arm after a covering arm
  or an unguarded `_` is `CHECK-UNREACHABLE-CASE-ARM`.
- `if` and `while` conditions must be `Bool`; there is no truthiness.
- `break` leaves the innermost `while` or `for`; `next` skips to its next
  iteration. Each stands alone on its line and neither crosses a block or
  function (`CHECK-LOOP-CONTROL`). In a block, `return` leaves the block.
- Assignment is a statement. There is no `x[i] = v`, `x.f = v` or `continue`.

## Expressions

- Literals: `42`, `3.14`, `1_000` (a `_` between digits is only visual; another
  `_` is `LEX-INVALID-NUMBER`), `"text"` (escapes `\" \\ \# \n \r \t`), `true`,
  `false`, `nil`. A minus sign is an operator, not part of the literal; an
  integer that does not fit is `CHECK-INT-RANGE`.
- Interpolation: `"total: #{n + 1}"`. Strings go in as is, `Json` as its JSON
  text, other data in their `IO.inspect` form. Keep the expression on one line;
  `\#{` is literal text. `case` patterns and `import` paths take plain strings
  only.
- Heredocs: `<<~NAME`, the text lines, then a line with only `NAME` (capitals,
  digits, `_`; `<<NAME`, `<<-NAME`, `<<~'NAME'` and `<<~name` are
  `LEX-UNEXPECTED-CHAR`). The smallest indentation among the text lines is
  removed, a space-only line becomes empty, and every line, the last too, ends
  with `\n`: `<<~T`, `  a`, `    b`, `T` is `"a\n  b\n"`. Escapes and `#{...}`
  work as in a string (indentation is removed first). The rest of the opener
  line is code (`puts(<<~T)`, `<<~T.length`, `f(<<~A, <<~B)`); inside `(...)`
  the call goes on after the end line. It needs two text lines or more
  (`LEX-HEREDOC-ONE-LINE`; write `"text\n"`); a tab in the indentation is
  `LEX-HEREDOC-INDENT`; no end line is `LEX-UNTERMINATED-HEREDOC`.
- Lists `[1, 2, 3]`; maps `{"a": 1, "b": 2}`. A repeated key keeps the last
  value at its first position.
- `[]`, `{}` and `Set.new([])` need a type from an annotation, parameter, field
  or function result (`CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`,
  `CHECK-EMPTY-SET-TYPE`): `m: Map[String, Int] = {}`. A non-empty list needs
  one element type.
- Struct construction names every field exactly once, in any order: `User(name:
  "Ana", age: 25)` (`CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD`).
- Update: `user.with(age: 31)` copies the struct with named fields changed. It
  takes at least one field, each named once, only by name (`user.with()` and
  `user.with(31)` are `PARSE-UNEXPECTED-TOKEN`), each with a value of the
  field's type (`[]` and `{}` take it; `CHECK-UNKNOWN-FIELD`,
  `CHECK-DUPLICATE-FIELD`, `CHECK-TYPE-MISMATCH`). The receiver runs first, then
  the values left to right, all seeing the old struct (`p.with(a: p.b, b: p.a)`
  swaps). It nests: `a.with(address: a.address.with(city: "Lima"))`. A bare
  `user.with(...)` is `CHECK-UNUSED-VALUE`; on a non-struct,
  `CHECK-UNKNOWN-METHOD`. A struct from another module updates only when that
  module exports it and you import it (`CHECK-IMPORT-NAME`).
  `return step(s.with(pos: s.pos + 1))` is a tail call.
- Enum variants are qualified by their type. Payload variants take positional
  arguments (`Option.Some("hi")`; `CHECK-ENUM-POSITIONAL-ARGS`); nullary ones
  take `Option.None` or `Option.None()`. Generic arguments come from payloads
  and expected types, so a nullary generic variant needs an expected type
  (`CHECK-ENUM-TYPE-INFERENCE`). An unknown variant is `CHECK-UNKNOWN-VARIANT`.
- Field access `user.name`; index `items[0]`, `stock["apple"]` (a missing key is
  `RUNTIME-KEY-NOT-FOUND`, a bad list index `RUNTIME-INDEX-OUT-OF-RANGE`).
  Strings cannot be indexed (`CHECK-NOT-INDEXABLE`: use `s.at(i)`). List
  indexing is O(log32 n); `for` visits items in order.
- `&name` references a top-level function without capturing locals: `f: Fn[Int,
  Int] = &double`, then `f.call(21)`. A block is also a function value and
  captures locals. Function values go in containers, fields, parameters and
  returns; signatures must match exactly. Bare function names are not values.
  There are no standalone lambdas, equality or JSON encoding; inspect prints
  `<Fn>`.

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

- `+ - * /` take two numbers of one type; no implicit conversion (`2 * 1.5` is
  `CHECK-TYPE-MISMATCH`: use `n.to_f` or `x.to_i!`). `+` also joins two Strings.
- `/` on Int truncates toward zero (`7 / 2` is `3`); `%` takes two Ints. A zero
  divisor is a runtime error, Float too (`RUNTIME-DIVISION-BY-ZERO`).
- `< <= > >=` take two numbers of one type (Strings: `a.compare(b) < 0`).
  Comparisons do not chain: `a < b and b < c` (`PARSE-CHAINED-COMPARISON`).
- `==` and `!=` take two values of one primitive type (Int, Float, Bool, String,
  Nil), or two ranges. Lists, maps, sets, structs, enums, Results, Json and Fn
  values cannot be compared: use `case` or a field (two sets are equal when
  `a.subset?(b) and b.subset?(a)`).
- `&&`, `||`, `!` take Bool and short-circuit; `and`, `or`, `not` are the same.
  `!` binds tightly: `!(a >= b)`. A `!` right after a name is part of it
  (`read!`). Operands run left to right.
- `x |> f(a)` means `f(x, a)`. The right side is a call with parentheses
  (`f(a)`, `Alias.f(a)`), optionally after `try`, else `PARSE-PIPE-TARGET`;
  pipes group left. A builtin with a method form is written with `.`
  (`CHECK-PIPE-METHOD`: `x.upcase`, not `x |> String.upcase()`). A multi-line
  chain goes in parentheses, one step per line; a leading `|>` does not continue
  a line, unlike a leading `.name`.

  ```ruby
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
  with no parentheses (`xs.each do`). A user function needs parentheses; one
  through an import alias may drop them (`Util.start do ... end`). The last
  parameter must be a `Fn` (`CHECK-BLOCK-TARGET`). Never `do || ... end` or
  `{ |x| ... }`.
- Parameter types come from the call; annotate when there is no context: `do |x:
  Int| ... end` (`CHECK-BLOCK-TYPE`).
- The last expression is the block's value; `return value` leaves only the
  block. A non-Void block gives a value on every path. `try` in a block needs a
  Result return known from the call (not in `map` or `sort_by`) and the block
  ends with `ok(...)`, else `CHECK-TRY-CONTEXT`. The block of `Task.map` gives a
  `Result[R]` and may use `try`; in the block of any `Lazy` method `try` always
  works (`lazy.md`).
- `case`, `while` and `for` headers may end with an optional `do`; that `do` is
  never a block. A call with a block in such a header is wrapped: `case (xs.map
  do |x| x end) do`.
- Blocks capture values when created; later outer changes do not affect them. A
  block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`): use
  `map`, `reduce` or a `for` loop. Block parameters cannot reuse visible names.
- A block is a `Fn[...]` value: return it, store it, pass it to `Task.spawn`, or
  make a BDD step with `BDD.step("pattern") do |ctx, args| ... end`.

## Result and try

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
```

- `ok(1)` is `Result[Int]`. An expected `Result[T]` checks the payload against
  T, even for `ok([])`.
- `error("bad")` needs an expected Result type from an annotation, an existing
  binding, a return, an argument, a field or a typed container element; `r =
  error("bad")` alone is `CHECK-RESULT-TYPE`. Lists and maps infer from the
  first element: `[ok(1), error("bad")]` infers, the reverse needs an
  annotation.
- `try` evaluates its Result operand once: success gives the payload, an error
  returns from the current function, which must return a Result
  (`CHECK-TRY-CONTEXT`; never in `main`). The operand and the function's success
  type may differ. `try` binds like unary `not`; parenthesize a larger operand.
  Success paths still return explicitly. The operand must be a Result: `try
  text.to_i`, not `try text.to_i!`. A `try` supplies `Result[T]` to its operand;
  the function's return type alone does not.
- `r.unwrap!` halts with `RUNTIME-UNWRAP-ERROR` on an error and passes its
  expected type to the operand as `Result[T]`. `unwrap_or` takes the expected T
  or the default's type and evaluates both arguments, left to right, even on
  success. `r.ok?` and `r.message` need a known Result type; `message` is `""`
  for a success.
- `ok(false)` and `ok(nil)` are successes. Results nest and hold lists, maps and
  structs; they have no equality, fields or indexing.
- Non-bang conversions (`s.to_i`) share the bang forms' syntax and 64-bit
  bounds but return an error on bad text; other runtime errors are not
  converted. `"x".to_i` is a Result, not `0`.
- `Result.Ok(x)` and `Result.Err(m)` equal `ok(x)` and `error(m)`, as values and
  `case` patterns (`Result.Ok(_)` also for `Result[Void]`).

## Forms from other languages

Rejected with a `help` line that names the Agentica form: `let x = 5`, `match`,
`when`, `if x then`, `elif`, `fn(x: Int)`, `lambda do`, `len(x)`, `Hash.new`,
`range(n)`, `break if x`, `loop do`, `puts(x) if ok`, `continue` (use `next`),
`;`, `while x {` ... `}`, single-quoted strings. `xs << x` is
`xs = xs.push(x)`.
