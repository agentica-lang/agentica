# Blocks and Result

The exact rule behind a checker error or a core question about blocks,
closures, `Result` and `try`. Builtin methods and `to_s`: `builtins.md`.

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
