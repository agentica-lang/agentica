# Program shape, declarations and types

The exact rule behind a checker error or a core question about the top level,
constants, declarations and types. Builtin methods and `to_s`: `builtins.md`.

## Program shape

- Top level holds `def`, `struct`, `enum`, `type` alias, `import` and constants;
  no statement runs there. `export` prefixes a function, struct, enum, alias or
  constant. An `extern "LIB"` block declares native functions, which count as
  `def`s, and resources and C structs, which count as types; a block with a
  resource or a struct counts as types as a whole (`native.md`).
- Order is checked: module doc and `import`s, constants, `struct`, `enum`,
  aliases and `extern` blocks with a resource or a struct (any order),
  `export def`, then private `def`.
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
  `Channel`, `Address`, `Task`, `ATS`, `Fn`, handles, `Void`). One exception:
  a whole initializer `ATS.new()` with its type written is a constant table,
  one per run, shared by every task and importer
  (`NAMES: ATS[String, Address[Msg]] = ATS.new()`; `tasks.md`).
- Other constants than scalar literals are built once, in dependency order,
  before `main`, and only if `main` can reach a reader. An initializer error
  (`BAD = [1][5]`) stops the program before `main`.
- The root file needs exactly one `def main() -> Void` with no parameters to run
  or compile (`CHECK-MAIN`); `check` accepts a file without one. Only `main`
  runs.
- Blocks end with `end`; `#` starts a comment. A newline ends a statement.
  Inside `(...)`, `[...]` and `{...}` an expression may span lines (trailing
  commas allowed); wrap a long expression in parentheses to split it.
- A line starting with `.name` continues the line before it, but not after the
  `end` of a `do` block (`CHECK-CHAIN-AFTER-END`); a `#` comment may end a line
  or sit between steps. These do not continue a line: a blank line, a `##`
  line, a line starting with `..`, `...` or `|>`, and a dot after the head of an
  `if`, `while`, `case` or `for`.

  ```ruby
  lines = File.foreach(path, 65536, 1000)
    .drop(1)                          # header
    .map { |line| parse(line) }
    .select(&big?)
  ```
- Reserved words: `def struct enum case do import export end if elsif else
  while for in return try true false nil and or not`.
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
  keeps insertion order, `K` is `Int`, `String` or `Bytes`. `Set[T]`: distinct,
  immutable, first-insertion order, `T` is `Int`, `String` or `Bytes`
  (`CHECK-SET-ELEMENT-TYPE`), prints `Set[1, 2]`, `==` in any order, not
  JSON-encodable.
- `Bytes`: immutable byte string (`references/bytes.md`); `Bytes` is a reserved
  name.
- `Result[T]`: `ok(value)` or `error(...)` holding an `Error` record
  (`language-blocks-results.md`); one type argument.
- `Optional[T]`: `some(value)` or `none`, for a value that may be missing
  (`language-blocks-results.md`).
- `Range`: `a..b` (includes `b`) or `a...b` (excludes it) over `Int`; prints
  `1..5`.
- `JSON.Value`: opaque; use `JSON` functions. `Fn[A, ..., R]`: a block or
  `&name`, the last type is the return; `Fn[Void]` takes no arguments.
- Opaque, with no constructor or `==`: `Process`, `Lazy[T]` (`lazy.md`),
  `Task[R]`, `TaskRef`, `Channel[T]`, `ATS[K, V]` (`tasks.md`), `Socket`,
  `Listener`, `HTTP.Client`, `HTTP.Server`, `Codec[T]` (`json.md`).
- `Address[T]`: a channel's send-only address (`ch.address`), data with `==`
  and text, no JSON, not a map key (`tasks.md`).
- Builtin enums, reserved: `Await[T]` (`Await.Done(value)`, `Await.TimedOut`;
  `tasks.md`), `JSON.Field[T]` (`Absent`, `Null`, `Value(x)`; `json.md`) and
  `TaskExit` (`Ok`, `Crashed`, `Cancelled`; `tasks.md`). `std/logger` exports
  the builtin `Logger.Level` (`Debug`, `Info`, `Warning`, `Error`) and
  `Logger.Event` (`logger.md`); they reserve no name.
- Builtin records: `File.Info`, `Process.Output`, `StructMember`, `TaskDown`.
  `std/http` exports the builtin `HTTP.Header`, `HTTP.Request`,
  `HTTP.Response`, `HTTP.ClientOptions` and `HTTP.ServerOptions`
  (`network.md`); they reserve no name.
- Type names start uppercase; variables, functions and fields start lowercase
  or `_`.

`type Names = List[String]` names any type and is transparent in every type
position. `export type` makes it importable. It adds no runtime type and cannot
be constructed or used as an enum pattern. Cycles are `CHECK-TYPE-ALIAS-CYCLE`;
errors in an expanded type point to the alias use; expansion stops at 1,000 type
references (`CHECK-TOO-DEEP`).

`type Matrix[T] = List[List[T]]` is pure substitution. A use needs one argument
per parameter (`Matrix` or `Matrix[Int, Int]` is `CHECK-UNKNOWN-TYPE`);
arguments are never inferred. Aliases may use aliases and imports
(`S.Matrix[Int]`).

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

enum Change[T]
  Added(T)
  Removed(T)
end
```

- A blank line follows the `end` of each `def`, `struct` and `enum`
  (`PARSE-MISSING-BLANK-LINE`). Every parameter and the return type need an
  annotation.
- Structs, enums and functions are top level only. Structs, enums, aliases and
  functions take type parameters. There are no user methods, nested functions,
  keyword arguments or overloads. Closures are blocks.
- A struct field may have a default: `retries: Int = 3`, left out in a
  constructor (`Options(name: "a")`; `CHECK-MISSING-FIELD` for one without). It
  follows the rules of a parameter default below, except a struct built with no
  arguments (`C()`), and has no order rule. `JSON.decode` still needs every
  key.
- A generic struct, `struct Box[T]`, is written with all its arguments in a
  type (`Box[Int]`, `M.Box[Int]`); a bare `Box` or a wrong count is
  `CHECK-UNKNOWN-TYPE`. A construction infers them from the field values, left
  to right, and from the expected type (annotation, parameter, field, return
  type): `Box(value: 1)` is `Box[Int]`. An empty `[]` or `{}` needs the expected
  type, and so does a parameter no value fixes (`CHECK-ENUM-TYPE-INFERENCE`);
  conflicting values are `CHECK-TYPE-MISMATCH`. Fields, `.with(...)` and
  printing work on the substituted type (`Box[Fn[Int, Int]]` does not print). A
  parameter is no `Map` key (`CHECK-MAP-KEY-TYPE`). `JSON.encode` takes a
  generic instance; `JSON.decode` and `JSON.schema` refuse one anywhere in the
  target (`CHECK-NOT-DECODABLE`).
- A generic function, `def first_or[T](xs: List[T], fallback: T) -> T`, is
  called without type arguments (`first_or[Int](...)` is
  `PARSE-UNEXPECTED-TOKEN`). The checker binds `T` from the typed arguments,
  left to right (a clash is `CHECK-TYPE-MISMATCH`), then from the expected type
  of the call, then from the block, whose open parameter types come from an
  annotation (`do |x: Int|`) or the uses in its body (else
  `CHECK-BLOCK-TYPE`). Arguments that need an expected type
  (`[]`, `{}`, `error(...)`, a payload-less generic variant) bind nothing. A
  parameter still open is `CHECK-ENUM-TYPE-INFERENCE` at the call. In the
  body `T` is opaque: store, return and pass it on, but no `==`, arithmetic,
  printing, fields or methods (`CHECK-TYPE-MISMATCH`, `CHECK-UNKNOWN-METHOD`),
  and it is no `Map` key or `Set` element; take an `Fn` parameter for
  behaviour. `JSON.encode(x)` and `JSON.from(x)` work, and each call checks
  that the bound type is encodable (`CHECK-NOT-ENCODABLE`, references/json.md).
  A parameter whose type has a type parameter takes `none`, `[]` or `{}` as its
  default (`x: T = 1` is `CHECK-TYPE-MISMATCH`).
  `&first_or` needs the expected `Fn` type: `xs.select(&name)` has it,
  `xs.map(&name)` does not.
- `User.members` (on the type, not a value) is a `List[StructMember]` of the
  fields in declaration order (`name: String`, `type: String` as source with
  aliases expanded). A field called `members` is still read as `user.members`.
- `User.codec` is the `Codec[T]` of a struct or enum JSON can read (`json.md`).
- A parameter may have a default: `def connect(host: String = "localhost", port:
  Int = 8080)`. A call omits trailing defaulted parameters (`connect("db")`).
  The default is a constant: an Int, Float or String literal (a minus before a
  number is fine; `#{...}` is not), `true`, `false`, `nil`, `none`, `[]`, `{}`
  (built again at each call, typed by the parameter), a payload-less enum
  variant (`Level.Info`), or the name of a module constant whose value is one
  of those (`limit: Int = LIMIT`). A parameter, not a field, may also default to
  a struct built with no arguments (`options: Options = Options()`), whose
  fields all need defaults. Anything else (`some(1)` too, `SUM = 1 + 2`) is
  `CHECK-DEFAULT-VALUE`; a wrong type is `CHECK-TYPE-MISMATCH` at the default.
- After a defaulted parameter every parameter needs a default
  (`CHECK-DEFAULT-ORDER`), except a last `Fn` parameter, which a block or the
  last argument always fills: with `def each_line(path: String, timeout_ms: Int
  = 1000, f: Fn[String, Void])`, `each_line("a.txt", 50)` gives `50` to `f`
  (`CHECK-TYPE-MISMATCH`).
- A call takes from the number of non-defaulted parameters up to all of them
  (`CHECK-ARITY`). A function value takes every argument (`.call` needs all).
  `main` and blocks take no defaults. A builtin can have defaults too
  (`agentica help NAME` shows them).
- Nesting goes 1000 levels at most (`PARSE-TOO-DEEP`, `CHECK-TOO-DEEP`); each
  operator of a chain counts a level, so 1,000 `+` already fail.
- Calls nest 10000 deep at most (`RUNTIME-STACK-OVERFLOW`). Tail calls do not
  count: only `return f(...)` or a last expression `f(...)` whose value is
  directly a user-function call (`1 + f(n - 1)` and builtin calls are not).
  Recurse over big inputs in tail form with an accumulator, or use `for`, `map`,
  `select`, `each`.
- A non-Void function's value is its last expression; `return` leaves early.
  A last `if` with `else` or a last `case` gives the last expression of the
  branch or arm that runs. Every path needs a value (`CHECK-MISSING-RETURN`): an
  `if` without `else`, a loop (put a value after `while true`), a binding, a
  `try` statement or a `Void` call at the end gives none. A Void function
  completes at `return` or at its end, and drops its last value
  (`CHECK-UNUSED-VALUE` still applies). A `Nil` function ends with `nil`. A
  statement after a `return` is `CHECK-UNREACHABLE-CODE`. `agentica fmt` writes
  a last `return x` as `x` (not for a `try` or `case` value, nor in a `Void` def
  or one whose result is a `Void` alias of the same file).
- A one-line def, `def double(x: Int) -> Int = x * 2`, is the def with
  `x * 2` as its body; `agentica fmt` writes a def whose body is one
  value this way when it fits and no comment sits from its `def` line to its
  `end` line. The expression starts on the line of `=` (it goes on only inside
  parentheses or a block, or on a line that starts with `.name`) and needs the
  return type; not for `Void` (`main` included), `case` or `if`
  (`PARSE-UNEXPECTED-TOKEN`). One-line defs may follow each other with no blank
  line, as constants; next to any other declaration the blank line stays
  (`PARSE-MISSING-BLANK-LINE`), except right
  after an import. In an `extern` block `= "name"` is the C name instead.
