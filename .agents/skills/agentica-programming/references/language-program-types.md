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
  `Channel`, `Task`, `ATS`, `Fn`, handles, `Void`).
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
  (`lazy.md`), `Task[R]`, `Channel[T]`, `ATS[K, V]` (`tasks.md`), `Socket`,
  `Listener`, `HttpClient`, `HttpServer`, `JSON.Codec[T]` (`JSON.codec(User)`,
  no printing or inspect; `json.md`).
- Builtin enums, reserved: `Await[T]` (`Await.Done(value)`, `Await.TimedOut`;
  `tasks.md`), `JsonField[T]` (`Absent`, `Null`, `Value(x)`; `json.md`) and
  `LogLevel` (`Debug`, `Info`, `Warning`, `Error`; `logger.md`).
- Builtin records: `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions`,
  `HttpServerOptions`, `FileInfo`, `ProcessOutput`, `LogEvent`, `StructMember`.
  `Name` is a struct you declare; its fields are typed and immutable.
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
- Structs, enums and functions are top level only. Structs, enums, aliases and
  functions take type parameters. There are no user methods, nested functions,
  keyword arguments or overloads. Closures are blocks.
- A struct field may have a default: `retries: Int = 3`. A constructor may
  leave it out (`Options(name: "a")`); a field without one must be given
  (`CHECK-MISSING-FIELD`). The default follows the rules of a parameter default
  below (`CHECK-DEFAULT-VALUE`, `CHECK-TYPE-MISMATCH`), with no order rule, and
  is built again at each construction. `.with(...)` and `JSON.decode` are not
  affected: a decode still needs every key.
- A generic struct, `struct Box[T]`, is written with all its arguments in a type
  (`Box[Int]`, `M.Box[Int]`); a bare `Box` or a wrong count is
  `CHECK-UNKNOWN-TYPE`. A construction infers them from the field values, left
  to right, and from the expected type (annotation, parameter, field, return
  type): `Box(value: 1)` is `Box[Int]`. An empty `[]` or `{}` needs the expected
  type, and so does a parameter no value fixes (`CHECK-ENUM-TYPE-INFERENCE`);
  conflicting values are `CHECK-TYPE-MISMATCH`. Fields, `.with(...)` and
  printing work on the substituted type (`Box[Fn[Int, Int]]` does not print).
  Parameter names follow the enum rules (`CHECK-REDEFINED-NAME`); a parameter
  is no `Map` key (`CHECK-MAP-KEY-TYPE`) and no type of a field named `with`.
  `JSON.encode` takes a generic instance; `JSON.decode` and `JSON.schema` refuse
  one anywhere in the target (`CHECK-NOT-DECODABLE`).
- A generic function, `def first_or[T](xs: List[T], fallback: T) -> T`, is
  called without type arguments (`first_or[Int](...)` is
  `PARSE-UNEXPECTED-TOKEN`). The checker finds them in four steps: the
  arguments with a type, left to right (a clash is `CHECK-TYPE-MISMATCH`); the
  expected type of the call, for the parameters still open; the arguments that
  need an expected type (`[]`, `{}`, `error(...)`, a payload-less variant of a
  generic enum, `&f` of a generic function), which bind nothing; the block,
  whose open parameter types must be annotated (`do |x: Int|`, else
  `CHECK-BLOCK-TYPE`) and whose result binds the rest (`R` in `Result[R]`).
  A parameter still open is `CHECK-ENUM-TYPE-INFERENCE` at the call. In the
  body `T` is opaque: store, return and pass it on, but no `==`, arithmetic,
  printing, fields or methods (`CHECK-TYPE-MISMATCH`, `CHECK-UNKNOWN-METHOD`),
  and it is no `Map` key or `Set` element; take an `Fn` parameter for
  behaviour. A parameter name may not be the name of a struct, enum or alias of
  the file, and a parameter whose type has a type parameter has no default.
  `&first_or` needs the expected `Fn` type (`f: Fn[List[Int], Int, Int] =
  &first_or`); `xs.filter(&name)` has it, `xs.map(&name)` does not.
- `User.members` (on the type, not a value) is a `List[StructMember]` of the
  fields in declaration order; `StructMember` has `name: String` and
  `type: String`, the field type as source with aliases expanded
  (`List[String]`, `Address`). An enum or resource is `CHECK-UNKNOWN-METHOD`,
  an alias `CHECK-UNKNOWN-TYPE`. A field called `members` is still read as
  `user.members`.
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
  and blocks take no defaults. A builtin can have defaults too
  (`Zlib.crc32(data, seed = 0)`; `agentica help NAME` shows them).
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
