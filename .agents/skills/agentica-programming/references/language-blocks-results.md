# Blocks, Result and Optional

The rules behind the checker errors on blocks, closures, `Result`, `try` and
`Optional`. Builtin methods and `to_s`: `builtins.md`.

## Blocks and closures

A block is a function written at the call site as the last argument: `xs.map do
|x| x * 2 end`, `run(5) do |n| n + 1 end`.

- `do |a, b| ... end` or `do ... end` follows the call's `)`, or a name with
  no arguments, which drops the empty `()`: `xs.each do`, `run do`,
  `Util.start do`. `{ |x| ... }` follows only a name with no arguments:
  `xs.map { |x| x * 2 }`; with arguments, use `do`. A bare name without a block
  is never a call. Keep `()` after `|>` and for a plain-name call in an `if` or
  guard condition (`if ready() do |x| ... end`); a block in braces goes in a
  condition or head only inside parentheses: `if (xs.any? { |x| x > 0 })`.
  The last parameter must be a `Fn` (`CHECK-BLOCK-TARGET`). Never
  `do || ... end`.
- Nothing chains after the `end` of a `do` block: `.name`, `[i]` or `|>` right
  after it, also on a leading-dot line or with the call in parentheses, is
  `CHECK-CHAIN-AFTER-END`. Use braces for one line,
  `xs.map { |x| f(x) }.join(", ")`, or bind the result to a name first.
- Parameter types come from the call, else from the uses in the body when they
  leave one type (`x + 1`: Int; `x.upcase`: String; `f(x)`, `Msg.Get(x)`: the
  parameter's type); annotate otherwise: `do |x: Int| ... end`
  (`CHECK-BLOCK-TYPE`; `x * 2` is Int or String, `x.size` many types; a field
  name counts every struct with it, builtin records such as `HTTP.Request`
  included, so `p.path` alone leaves several).
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
- A block is a `Fn[...]` value: return it, store it, pass it to `Task.spawn`.

## Lambdas

A lambda is a block written as a value, for a function value of its own:
`add = ->(x: Int) { x + base }`, `answer = -> { 42 }`.

- Parentheses hold the parameters, and none means no parentheses (`-> { 1 }`,
  never `->() { 1 }`). The body is always in braces, over one line or several;
  never `->(x) do ... end`, `lambda`, `proc` or `->x`.
- The block rules hold: parameter types from the expected `Fn` (an annotated
  variable, parameter, field, list or map item, return type), annotations or
  the uses in the body (`->(x) { x + 1 }`), else `CHECK-BLOCK-TYPE`; `try`
  needs a known `Result` result, so annotate:
  `f: Fn[String, Result[Int]] = ->(s) { ... }`; `return` leaves the lambda.
- Where a call takes a block, a lambda inside the parentheses is that block,
  typed from the call: `xs.map(->(x) { x * 2 }).sum`, and in a pipe into
  methods, `xs |> map(->(x) { x * 2 }) |> sum()`. A `do ... end` block never
  goes inside the parentheses. A lambda cannot call itself (use `def`), and one
  dropped as a statement is `CHECK-UNUSED-VALUE`.

## Result and try

Signatures: `builtins.md`.

- An expected `Result[T]` checks the payload against T, even for `ok([])`.
- A failed Result holds an `Error`, a builtin record: `kind: String`
  (`"error"` by default), `message: String`, `code: Optional[Int]`,
  `details: Map[String, String]`, `cause: Optional[Error]` and `location:
  String` (`path:line:col` of the `error(...)` or builtin call, `""` when
  unknown). `error(e) ->` binds it: use `e.message` where a String goes
  (`"x" + e` and `e.include?(...)` are errors); `"#{e}"`, `puts(e)` and
  `e.to_s` give the message. `error(e)` with an Error passes it on unchanged,
  as a Result of another type. A text literal in the pattern
  (`error("timeout") ->`) is `CHECK-PATTERN-TYPE`: write
  `error(e) if e.message == "timeout"`.
- `error("unique failed", kind: "db.constraint", code: 19, cause: e)`: named
  arguments after the message, each optional, any order; `code` and `cause`
  are stored as `some(...)` (`code: some(19)` is an error). A `kind:` literal
  is a dotted name of `a-z`, `0-9`, `_` (`CHECK-ERROR-KIND`). Branch on
  `e.is_a?("db")` (the kind `db` or any `db.*`; `kind_of?` too) or `e.code`,
  never on the message. `Error(...)` is `CHECK-ERROR-CONSTRUCTOR`; only
  `error(...)` builds one.
- Builtin errors have kinds: `argument` (a bad argument value), `io.*`
  (`not_found`, `permission`, `exists`, `is_directory`, `not_directory`,
  `too_large`, `eof`, `closed`, `timeout`, `failed`), `net.*` (`timeout`,
  `refused`, `host_not_found`, `closed`, `eof`, `tls`, `failed`), `http.*`
  (`protocol`, `too_large`, `closed`), `process.*` (`not_found`, `timeout`,
  `closed`, `eof`, `failed`), `task.crashed`, `task.cancelled`,
  `task.timeout`, `channel.*` (`closed`, `timeout`, `gone`), `json.parse`,
  `json.decode`, `number.parse`, `number.range`, `text.encoding`, `zlib.data`,
  `zlib.too_large`, `crypto.*` (`auth`, `key`, `failed`), `system.env`,
  `native.failed`, `native.timeout`, `test.failed`, and the refusals of the
  `--deny-*` flags, `denied.env`, `denied.fs`, `denied.net` and `denied.run`
  (`e.is_a?("denied")` matches all). A find with no match keeps `"error"`. An
  OS error has its errno as `code` (the number differs between systems; the
  kind does not), a refused HTTP head its status.
- `std/` kinds: `http.*` and `net.timeout` (std/http), `archive.format`,
  `archive.unsafe`, `archive.too_large`, `archive.timeout`,
  `archive.not_found`, `toml.parse`, `toml.decode`, `regex.syntax`,
  `option_parser.parse` (a bad command line), `option_parser.help`
  (`--help`), `binary.too_large`, `channel.gone` and `channel.timeout`
  (std/actor); a bad argument is `argument`. A std/ function that passes on a
  builtin's error keeps its kind and code. The table: the Error page of the
  library.
- `e.inspect` and a printed failed Result show `error("text")`, plus the
  fields that are not their default (never `location`). `==` on Errors skips
  `location`. `Error` is a reserved type name (`CHECK-REDEFINED-NAME`).
- `error("bad")` needs an expected Result type from an annotation, an existing
  binding, a return, an argument, a field or a typed container element; `r =
  error("bad")` alone is `CHECK-RESULT-TYPE`. Lists and maps infer from the
  first element: `[ok(1), error("bad")]` infers, the reverse needs an
  annotation. A block of unknown result type (`map`, `Native.memory_pointer`)
  takes it from its `ok(...)`, so `return error("bad")` may come first.
- `try` evaluates its Result operand once: success gives the payload, an error
  returns from the current function, which must return a Result
  (`CHECK-TRY-CONTEXT`; never in `main`). The operand and the function's success
  type may differ. `try` binds like unary `not`; parenthesize a larger operand.
  The operand must be a Result: `try text.to_i`, not `try text.to_i!`.
- `r.unwrap!` halts with `RUNTIME-UNWRAP-ERROR` on an error and passes its
  expected type to the operand as `Result[T]`. `unwrap_or` takes the expected T
  or the default's type and evaluates both arguments, left to right, even on
  success. `r.ok?` and `r.message` need a known Result type; `message` is `""`
  for a success.
- `ok(false)` and `ok(nil)` are successes. Results nest and hold lists, maps and
  structs; they have no fields or indexing. `r == ok(1)` and `r == error("x")`
  compare the tag and the payload or the Error.
- Non-bang conversions (`s.to_i`) share the bang forms' syntax and 64-bit
  bounds but return an error on bad text; other runtime errors are not
  converted.
- `Result.Ok(x)` and `Result.Err(m)` equal `ok(x)` and `error(m)`, as values and
  `case` patterns (`Result.Ok(_)` also for `Result[Void]`).

## Optional

Signatures: `builtins.md`.

- `Optional[T]` is a value that may be missing; it goes anywhere a type does
  (fields, parameters, returns, list and map items) and nests.
- `some(1)` is `Optional[Int]`. `none` needs an expected Optional type, as
  `error` does (`CHECK-OPTIONAL-TYPE`): `age: Optional[Int] = none`.
- A field or parameter may default to `none` (`port: Optional[Int] = none`);
  `some(1)` is not a constant (`CHECK-DEFAULT-VALUE`). `T` may be a type
  parameter: `def first_or_none[T](xs: List[T]) -> Optional[T]`.
- `case o` needs both arms, `some(n) ->` and `none ->` (or `_`). Patterns nest,
  also in a user variant (`enum E` with `A(Optional[Int])`: `E.A(some(0))`,
  `E.A(none)`, `ok(some(n))`). An arm with a literal or a nested variant
  covers nothing, so end with a names-only arm (`E.A(opt)`, `E.A(_)`, `some(n)`)
  or `_`, else `CHECK-NON-EXHAUSTIVE-CASE`.
- `m.get(k)` and `s.index_of(part)` give an Optional. A missing value that is
  normal is an Optional; a failure with a reason is a Result (`List.find` and
  `Lazy.find` give `error("not found")`).
- `==` compares two Optionals of a type with `==`: `o == none`,
  `o == some(3)`. Prints as `some(3)` or `none`; JSON: `json.md`.
- `some`, `none`, `ok` and `error` cannot name a variable, function or field.

## Design patterns

Strategy: an `Fn` parameter (`&name` or a block). Factory: a function returning
`Result[T]`. Builder: field defaults and `.with(...)`. State machine: an enum
and `case`. Command: enum variants applied with `reduce`. Decorator: a function
taking and returning an `Fn` (it returns a lambda that calls `f`). Observer: a
struct holding a `List[Fn[...]]`, called with `map`.

Composition root: `main` builds the collaborators (tables, stores, the clock,
such as `&Time.now_ms`) and passes them in; a function never builds what it
calls. Boundary: write the body as `Result[T]` with `try`, and convert once
where the caller needs another type:

```ruby
def handler(call: Call) -> Reply
  case body(call)
    ok(reply) -> reply
    error(e) -> fail(call, e.message)
  end
end
```
