## 6. Minimal semantic rules

The grammar determines what can be written. The following rules determine which programs are valid and how they run. They are the rules the interpreter implements.

### Types and inference

| Type | Rule |
|---|---|
| `Int` | Signed 64-bit integer; overflow is a runtime error |
| `Float` | IEEE 754 binary64 |
| `Bool` | Only `true` and `false`; there is no truthiness |
| `String` | Unicode text; concatenation with `+` |
| `Nil` | A single data value, `nil` |
| `Void` | Completion without a usable value; no literal |
| `List[T]` | Homogeneous, immutable list; `Int` indexes, from zero |
| `Map[K, V]` | Homogeneous, immutable dictionary; the key `K` is `Int` or `String`; keeps insertion order |
| `Result[T]` | Exactly one payload type; successful `ok(value)` or String-valued `error(message)` |
| `Json` | Opaque JSON value, accessed through the `JSON` module |
| `Range` | Immutable range of `Int` values: `a..b` includes `b`, `a...b` excludes it |
| `Fn[A, ..., R]` | Function value (`&name` or a block); final type is its return, preceding types are parameters |
| `Task[R]` | Opaque lightweight task with exactly one result type |
| `Enum[T, ...]` | User-declared nominal sum type; type parameters are declared on the enum |
| Declared struct | Nominal type, typed and immutable fields |

Network handles (`Socket`, `Listener`, `HttpClient`, `HttpServer`) and the builtin records (`Header`, `HttpRequest`, ...) are described in [TCP, TLS and HTTP](06d-io-and-network.md).

Parameters and the return type of functions require an annotation. Local variables can be inferred from the initializer:

```ruby
count = 3
names: List[String] = []
```

An empty list needs an expected type, which can come from an annotation, a parameter, a field, or the return type of a function. A non-empty list must have elements of the same type. There is no implicit numeric conversion and no dynamic `Any` type.

`Nil` is not a nullable wildcard: `name: String = nil` is invalid. Define an enum such as `Option[T]` when an optional value is needed.

### Operators

- `+`, `-`, `*`, and `/` accept two operands of the same numeric type. Also, `+` concatenates two `String` values.
- Integer division truncates toward zero. `%` accepts only integers and is defined by `a = (a / b) * b + (a % b)`.
- Dividing by zero is a runtime error, also for `Float`. Integer operations that do not fit in `Int` produce an error.
- The ordering operators accept only two numbers of the same type.
- `==` and `!=` accept values of the same primitive type, or two `Range` values: two ranges are equal when start, end and kind (`..` or `...`) match. The core has no list or struct equality.
- `..` and `...` accept two `Int` values and give a `Range`; anything else is `CHECK-TYPE-MISMATCH`.
- `and`, `or`, and `not` accept only `Bool`. `&&`, `||`, and `!` are the same operators with the same precedence. A `!` directly after a name belongs to the name (`read!`), and `!=` is inequality; a standalone `!` is `not`.
- There is no user-defined operator overloading.

Expressions, arguments, and constructor fields are evaluated from left to right. A float comparison follows IEEE 754; in particular, a NaN is not equal to itself.

### Variables and scope

The first assignment introduces a variable in the current scope. A later assignment changes its value without changing its type. An annotation can appear only when the variable is introduced.

Each function and each control block introduces a lexical scope. A visible variable cannot be shadowed by another with the same name. An assignment without an annotation updates the visible variable if it already exists; otherwise it introduces a local in the current block.

Parameters and the `for` variable are already-initialized bindings. The `for` variable is local to the body and cannot be reassigned. Variables created in a block are not visible after its `end`.

```ruby
count = 0
while count < 3
  puts("hello")
  count = count + 1
end
```

### Void completion

`Void` has no literal or usable payload. It is permitted as a function return, the final type of `Fn`, or the completion type of `Result`/`Task`. Bare Void variables, parameters, fields, List elements, and Map values are `CHECK-VOID-TYPE`. Wrappers such as `List[Result[Void]]` are valid data.

A Void call may be a statement or be forwarded from a Void function with return another_void_call(). Assignment, argument passing, construction, operators, and inspection of bare completion fail with CHECK-VOID-VALUE. The same restriction applies to Result.unwrap!(Result[Void]), Task.await(Task[Void]), and successful try on Result[Void].

ok() infers Result[Void] and prints ok(); ok(nil) is Result[Nil] and prints ok(nil). Result[Void] functions explicitly return ok() or error(message); try still requires an enclosing Result-returning function. Result.unwrap_or needs a data fallback and cannot operate on Result[Void].

### Functions and entry point

- Functions can be called before their declaration and can be recursive.
- There is no overloading, default values, or named arguments in ordinary functions.
- A function with a return type other than `Void` must return on every reachable path. In the initial checker, a loop does not by itself guarantee a return.
- The last expression does not return implicitly. Exhaustive `case` is a statement; a non-`Void` function may use it to return only when every arm returns.
- `return` without a value completes a `Void` function. Functions returning `Nil` explicitly use `return nil`.
- Reaching the end of a `-> Void` function completes without a value.
- An executable must declare exactly one `main() -> Void` function with no parameters.

### Enums and pattern matching

Enums are nominal sum types and may declare type parameters. Variant names are qualified by the enum; payloads are positional, and a nullary variant is constructed with or without empty parentheses (`Command.Show` or `Command.Show()`). Constructor type parameters are inferred from payloads and the expected enum type; unresolved or conflicting parameters are errors. Imported enum variants use the import alias plus enum and variant names.

`case value ... end` is a statement; a `do` after the value is allowed but not needed. An arm may put one simple statement on the arrow line (`1 -> puts("one")`); more lines of the same arm may follow. Patterns are primitive literals, `_`, `ok(...)`/`error(...)` for Results, or a qualified enum variant with one direct binding or `_` discard per payload position. Bindings are local to the arm; nested patterns and guards are not supported. Enum values require every declared variant unless there is a catch-all `_`. `Result[T]` can be matched as `Result.Ok(value)` / `Result.Err(message)`; use `Result.Ok(_)` to discard a payload, including the `Void` success payload. Every non-enum case, including `Bool` and `Nil`, requires `_`. A catch-all is last; duplicate and unreachable arms are rejected. The checker reports enum inference failures as `CHECK-ENUM-TYPE-INFERENCE`, invalid patterns as `CHECK-PATTERN-TYPE`, missing coverage as `CHECK-NON-EXHAUSTIVE-CASE`, and covered arms as `CHECK-UNREACHABLE-CASE-ARM`.

```ruby
enum Option[T]
  Some(T)
  None
end

def display(option: Option[Int]) -> Void
  case option
    Option.Some(item) -> puts(String.from_int(item))
    Option.None -> puts("empty")
  end
end
```

### Structs and lists

All fields of a constructor are required and given exactly once. The order of named fields is free. There are no default fields and no extra fields.

```ruby
user = User(age: 25, name: "Ana")
```

List indexes must be between zero and length minus one; a negative or out-of-range index is an error. Indexing costs O(n) in this interpreter; prefer `for` for traversal rather than repeated indexed access. `for` iterates over `List[T]` in order, and over a `Range` (next section). Slices and string indexing are not supported in the core.

### Ranges

`a..b` is the range of `Int` values from `a` to `b`, both included; `a...b` excludes `b`, as in Ruby. Both operands are `Int`. The result has the builtin type `Range`, a small immutable value (start, end and kind); it never holds a list.

```ruby
for i in 0...3 do
  puts(i)          # 0, 1, 2
end
```

- `for x in range` yields each `Int` in order without building a list. A range whose end is before its start is empty; there is no reverse iteration (use `downto`, or `List.reverse` on `to_a`). Iteration up to the largest `Int` does not overflow. Each iteration costs one step (even with an empty body), plus its body. The range is evaluated once, so assigning to its variable in the body does not change the loop.
- `Range` functions:

  | Function | Result |
  |---|---|
  | `Range.size` | the number of values; `RUNTIME-INTEGER-OVERFLOW` at the receiver when it does not fit in `Int` (`(0..9223372036854775807).size`) |
  | `Range.to_a` | the values in order; above 1048576 values, `RUNTIME-INVALID-COUNT` at the receiver |
  | `Range.include?` | whether the value is in the range |
  | `Range.each` | calls `f` on each value in order |
  | `Range.first`, `Range.last` | the first and last included values; `error("the range is empty")` for an empty range. Unlike Ruby, `(1...5).last` is `ok(4)` |

- `Int` methods for loops, all returning `Void`: `n.times(f)` calls `f` with `0` to `n - 1` (nothing when `n <= 0`); `a.upto(b, f)` with `a` up to `b` (nothing when `b < a`); `a.downto(b, f)` with `a` down to `b` (nothing when `b > a`). `f` is `Fn[Int, Void]`, usually a block. Each call of `f` (and `Range.each`'s) costs one step plus the block. A negative literal receiver needs parentheses: `-5.times do ... end` is `-(5.times ...)`, a `CHECK-VOID-VALUE` whose help says to write `(-5).times`.
- Text form: `1..5` and `1...5`, as Ruby's `inspect`; `to_s`, interpolation and `IO.inspect` all show it. Ranges have `==` (start, end and kind match). They are not JSON-encodable and cannot be `Map` keys.
- Ranges of `String` or `Float` and `step` are not supported.

### Maps

`Map[K, V]` associates keys with values. The key `K` can only be `Int` or `String`; `V` can be any type. `Map` takes exactly two type arguments.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- A literal uses braces and `key: value`; it allows several lines and a trailing comma. An empty `{}` needs an expected type, like `[]`; without it the diagnostic is `CHECK-EMPTY-MAP-TYPE` (`CHECK-EMPTY-LIST-TYPE` is only for `[]`).
- `m[key]` returns the value. The key must have type `K`. A missing key is a runtime error.
- If a literal repeats a key, the last value wins; the key keeps its first-insertion position. Replacing a key with `Map.put` also preserves its position.
- Maps are immutable, like lists: there is no `m[key] = value`. `Map.put` returns a new map and leaves the original intact.
- There is no map equality and no `for` over a map; iterate with `Map.keys`, which returns the keys in insertion order.
- Lookup, `Map.has_key?` and `Map.put` take O(log32 n) steps in the map size, excluding key hashing and comparison, so they are effectively constant-time. `Map.size` is O(1); `Map.keys` is O(n). An update shares unchanged storage with the old map instead of copying it.

### Result and propagation

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String
```

- `Result.Ok(x)`, `Result.Ok()` and `Result.Err(m)` are the same as `ok(x)`, `ok()` and `error(m)`. In `case`, the patterns `ok(v)` and `error(m)` are the same as `Result.Ok(v)` and `Result.Err(m)`.
- `Result[T]` is builtin, not a user enum. It can nest and contain any valid payload type. Results have no equality, fields, or indexing.
- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload against `T`, including empty lists/maps.
- `error("bad")` needs an expected Result type from an annotation, existing binding, parameter, field, return, or typed container element. Otherwise it is `CHECK-RESULT-TYPE`; no success type is guessed.
- `Result.unwrap!` passes its expected output type `T` to the operand as `Result[T]`. On an error it halts with `RUNTIME-UNWRAP-ERROR`, the stored message, and the unwrap call span.
- `Result.unwrap_or` uses the expected output type, or infers it from the default. Both arguments run eagerly, left to right, even for a success.
- `Result.ok?` and `Result.message` need an argument whose Result type is known. A success's message is `""`. `ok(false)` and `ok(nil)` are successes.
- Container inference still uses the first element: `[ok(1), error("bad")]` infers, but the reverse order needs an annotation.
- Non-bang String conversions use the same signed-decimal syntax and integer bounds as bang forms, but invalid text/overflow return errors rather than halting. Unrelated runtime failures are not converted to Results.
- `IO.inspect` prints recursive `ok(...)` / `error(...)` forms and returns its argument. Error values do not print diagnostics or change the run's exit code.
- `try` has unary precedence: it evaluates one `Result[T]` operand once and produces `T` on success, or returns its error from the current function. Only a function returning `Result[...]` may use it (`CHECK-TRY-CONTEXT` otherwise). Operand and enclosing success types may differ. An expected expression type `T` supplies `Result[T]` to the operand; the enclosing return type alone does not infer it. A success still needs an explicit return from the function.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

### Function values

`Fn` is a reserved builtin name. `f: Fn[Int, Int] = &double` refers to a declared function with exactly those parameter and return types; `f.call(21)` invokes it. References can travel through lists, maps, parameters, returns, and fields. A bare function name remains invalid as a value. Functions have no equality, field access, indexing, or JSON encoding; `IO.inspect` prints `<Fn>`.

### Blocks and closures

A block is a function written at the call site, as the last argument of a call or method call:

```ruby
doubled = xs.map do |x|
  x * 2
end
evens = xs.filter do |x| x % 2 == 0 end
total = xs.reduce(0) do |sum, x| sum + x end
xs.each do |x|
  puts("item #{x}")
end
```

- **Where.** `do |a, b| ... end` (or `do ... end` without parameters) right after the `)` of a call, or after a method name without parentheses: `xs.each do ... end`. A user function always needs its parentheses: `run(1) do ... end`, `start() do ... end`; only a function reached through an import alias may drop them, like a module function (`Util.start do ... end`). The block becomes the last argument, so the called function's last parameter must be a `Fn` (`CHECK-BLOCK-TARGET` otherwise, for user functions and builtins alike). `do || ... end` is rejected; write `do ... end`.
- **Lines.** The body may follow the parameters on the same line (`do |x| x * 2 end`) or start on the next one. Blocks may span lines inside parentheses: `puts(String.join(xs.map do |x| ... end, ","))`.
- **`case`, `while`, `for`.** These headers may end with an optional `do`: `case x do`, `while !done do`, `for x in xs do`. That `do` belongs to the header and is never a block. A call with a block in these headers needs parentheses: `case (xs.map do |x| x end) do`.
- **Parameter types** come from the call: the parameter types of the expected `Fn`, or the builtin's rule (`xs.map` gives `x` the element type). They may be annotated: `do |x: Int| ... end`. With neither, `CHECK-BLOCK-TYPE`. A wrong number of parameters is `CHECK-ARITY`.
- **Result.** `return value` leaves the block, not the enclosing function. Without `return`, the value of the last expression statement is the block's value. The result type comes from the expected `Fn` (user functions, `each`, `any?`, `all?`, `filter`, and `reduce`, whose result is the accumulator type); for `map` and `sort_by` it comes from the body, where every `return` and the last expression must agree (`CHECK-TYPE-MISMATCH`). A non-`Void` block must give a value on every path (`CHECK-MISSING-RETURN`). When the result is `Void`, the last statement gives no value.
- **`try`** inside a block returns the error from the block, so the block's result must be `Result[...]` (`CHECK-TRY-CONTEXT` otherwise); write the success as `ok(...)`. The result must be known from the call (a user function's `Fn[..., Result[T]]`), so `try` is not available in `map` and `sort_by` blocks, whose result is inferred.
- **Capture by value.** A block sees every variable visible where it is written and keeps their values from the moment it is created; later assignments outside do not change it. Assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`: use `reduce` or a `for` loop. Block parameters and new variables cannot reuse a visible name (`CHECK-SHADOWED-NAME`).
- **Values.** A block has type `Fn[A, ..., R]` and works wherever a function value does: stored, returned, passed to `Task.spawn` through a variable, or made into a BDD step with `BDD.step(pattern) do |ctx, args| ... end` (see "`agentica test`"). It shares the caller's step budget and call-depth limit. Blocks have no equality or JSON form; `IO.inspect` prints `<Fn>`.
