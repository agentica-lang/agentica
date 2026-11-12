# Blocks, Result and Optional

The exact rule behind a checker error or a core question about blocks,
closures, `Result`, `try` and `Optional`. Builtin methods and `to_s`:
`builtins.md`.

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

A lambda is a block that no call takes, for a function value of its own:
`add = ->(x: Int) { x + base }`, `answer = -> { 42 }`.

- Parentheses hold the parameters, and none means no parentheses (`-> { 1 }`,
  never `->() { 1 }`). The body is always in braces, over one line or several;
  never `->(x) do ... end`, `lambda`, `proc` or `->x`.
- The block rules hold: parameter types from the expected `Fn` (an annotated
  variable, parameter, field, list or map item, return type), annotations or
  the uses in the body (`->(x) { x + 1 }`), else `CHECK-BLOCK-TYPE`; `try`
  needs a known `Result` result, so annotate:
  `f: Fn[String, Result[Int]] = ->(s) { ... }`; `return` leaves the lambda.
- Where a call takes a block, write the block: `xs.map(->(x) { ... })` is
  `CHECK-LAMBDA-BLOCK`. `.call(...)` takes no block, so a lambda may be its
  last argument. A lambda cannot call itself (use `def`), and one dropped as a
  statement is `CHECK-UNUSED-VALUE`.

## Result and try

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
```

- An expected `Result[T]` checks the payload against T, even for `ok([])`.
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
- A dropped `Result` from any call is `CHECK-UNUSED-RESULT`: `try` it, `case`
  it, `.unwrap!`, or write `_ = f(x)`.
- `ok(false)` and `ok(nil)` are successes. Results nest and hold lists, maps and
  structs; they have no fields or indexing. `r == ok(1)` and `r == error("x")`
  compare the tag and the payload or message.
- Non-bang conversions (`s.to_i`) share the bang forms' syntax and 64-bit
  bounds but return an error on bad text; other runtime errors are not
  converted. `"x".to_i` is a Result, not `0`.
- `Result.Ok(x)` and `Result.Err(m)` equal `ok(x)` and `error(m)`, as values and
  `case` patterns (`Result.Ok(_)` also for `Result[Void]`).

## Optional

```text
some(value: T) -> Optional[T]
none -> Optional[T]
```

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
- `o.unwrap_or(default)`, `o.unwrap!` (halts with `RUNTIME-UNWRAP-NONE` on
  `none`), `o.map do |x| x + 1 end`, `o.some?`, `o.none?`,
  `o.to_result("missing")` (a Result for `try`).
- `m.get(k)` and `s.index_of(part)` give an Optional. A missing value that is
  normal is an Optional; a failure with a reason is a Result (`List.find` and
  `Lazy.find` give `error("not found")`).
- `==` compares two Optionals of a type with `==`: `o == none`,
  `o == some(3)`. Prints as `some(3)` or `none`. JSON writes `none` as `null`
  and reads `null` or a missing key as `none` (`json.md`).
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
    error(message) -> fail(call, message)
  end
end
```
