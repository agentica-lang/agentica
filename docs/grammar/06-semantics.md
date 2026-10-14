## 6. Minimal semantic rules

The grammar determines what can be written. The rules below determine which programs are valid and how they run.

### Types and inference

| Type | Rule |
|---|---|
| `Int` | Signed 64-bit integer; overflow is a runtime error |
| `Float` | IEEE 754 binary64 |
| `Bool` | Only `true` and `false`; there is no truthiness |
| `String` | Unicode text; concatenation with `+` |
| `Nil` | A single data value, `nil` |
| `Void` | Completion without a usable value; no literal |
| `List[T]` | Homogeneous, immutable list; `Int` indexes from zero |
| `Map[K, V]` | Homogeneous, immutable map; the key `K` is `Int` or `String`; keeps insertion order |
| `Result[T]` | `ok(value)`, or `error(message)` with a `String` message |
| `Json` | Opaque JSON value, used through the `JSON` module |
| `Range` | Immutable `Int` range: `a..b` includes `b`, `a...b` excludes it |
| `Fn[A, ..., R]` | Function value; the last type is its return, the others are its parameters |
| `Task[R]` | Opaque lightweight task with one result type |
| `Enum[T, ...]` | User-declared nominal sum type |
| Declared struct | Nominal type with typed, immutable fields |

Parameters and function return types need annotations. Local variables may be inferred from the initializer, as in `count = 3`. An empty list or map needs an expected type, from an annotation, a parameter, a field or a return type: `names: List[String] = []`. A non-empty list has one element type. There is no implicit numeric conversion and no `Any` type. `Nil` is not a nullable wildcard: `name: String = nil` is invalid; use an enum such as `Option[T]`.

### Operators

- `+`, `-`, `*` and `/` take two operands of one numeric type; `+` also concatenates `String`s. Integer `/` truncates toward zero, and `%` takes integers only, with `a = (a / b) * b + (a % b)`. Division by zero is `RUNTIME-DIVISION-BY-ZERO`, for `Float` too. An integer result outside `Int` is an error.
- Ordering operators take two numbers of one type. `==` and `!=` take one primitive type, or two `Range` values (equal when start, end and kind match). There is no list or struct equality. `..` and `...` take two `Int` values.
- `and`, `or` and `not` take only `Bool`. `&&`, `||` and `!` are the same operators. A `!` directly after a name belongs to it (`read!`); `!=` is inequality.
- There is no operator overloading. Expressions, arguments and constructor fields are evaluated left to right. Float comparisons follow IEEE 754: NaN is not equal to itself.

### Variables and scope

The first assignment introduces a variable in the current scope, and an annotation is allowed only there. Later assignments change its value, not its type. Each function and control block is a lexical scope. An assignment without annotation updates a visible variable of that name, or else introduces a local in the current block. A new name cannot shadow a visible one. Parameters and the `for` variable are initialized bindings; the `for` variable cannot be reassigned. Variables created in a block are not visible after its `end`.

### Void completion

`Void` has no literal and no usable payload. It is allowed as a function's return type, as the last type of `Fn`, and as the completion type of `Result` or `Task`. Bare Void variables, parameters, fields, list elements and map values are `CHECK-VOID-TYPE`. Wrappers such as `List[Result[Void]]` are valid.

A Void call may be a statement, or be returned from a Void function. Assigning, passing, constructing, operating on or inspecting a Void result is `CHECK-VOID-VALUE`, and so is `Result.unwrap!` on `Result[Void]`, `Task.await` on `Task[Void]`, or a successful `try` on `Result[Void]`. `ok()` infers `Result[Void]`, and `ok(nil)` is `Result[Nil]`. `Result.unwrap_or` cannot operate on `Result[Void]`.

### Functions and entry point

- Functions can be called before their declaration, and can be recursive. Arguments are positional: there is no overloading, default value or named argument for ordinary functions.
- A function with a non-`Void` return type must return on every reachable path. A loop does not guarantee a return.
- The last expression does not return implicitly. `case` is a statement; a non-`Void` function may end with an exhaustive `case` only when every arm returns.
- `return` without a value completes a `Void` function. A `Nil` function uses `return nil`.
- An executable declares exactly one `main() -> Void` with no parameters.

### Enums and pattern matching

Enums are nominal sum types and may declare type parameters. Variants are qualified by their enum, and payloads are positional. A nullary variant is written `Command.Show` or `Command.Show()`. Constructor type parameters come from the payloads and the expected type; unresolved or conflicting ones are errors.

`case value ... end` is a statement. An arm may put one simple statement on the arrow line (`1 -> puts("one")`), and more lines of the same arm may follow. A pattern is a primitive literal, `_`, `ok(...)` or `error(...)`, or a qualified variant with one binding or `_` per payload position. Bindings are local to the arm. Nested patterns and guards are not supported.

Enum values need every variant, unless there is a catch-all `_`. `Result[T]` matches as `Result.Ok(value)` and `Result.Err(message)`, or as `ok` and `error`; `Result.Ok(_)` discards the payload. Every other `case`, including one on `Bool` or `Nil`, needs `_`. A catch-all is the last arm, and duplicate or unreachable arms are rejected. The codes are `CHECK-ENUM-TYPE-INFERENCE`, `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE` and `CHECK-UNREACHABLE-CASE-ARM`.

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

A struct constructor gives every field exactly once, by name, in any order. There are no default or extra fields.

A list index runs from zero to length minus one; a negative or out-of-range index is `RUNTIME-INDEX-OUT-OF-RANGE`. Indexing costs O(n) here, so use `for` for traversal. `for` iterates a `List` in order, or a `Range`. The core has no slices and no string indexing.

### Ranges

`a..b` includes `b`; `a...b` excludes it, as in Ruby. A `Range` is a small immutable value (start, end and kind); it never holds a list.

```ruby
for i in 0...3 do
  puts(i)
end
```

- `for x in range` yields each `Int` in order, without a list. An end before the start is empty, and there is no reverse iteration. Iterating up to the largest `Int` does not overflow. Each iteration costs one step plus its body. The range is evaluated once.
- `Int.times`, `upto` and `downto` (`n.times(f)`, `a.upto(b, f)`, `a.downto(b, f)`) return `Void`. A negative literal receiver needs parentheses: `(-5).times do ... end`; `-5.times do ... end` is `-(5.times ...)`, a `CHECK-VOID-VALUE`.
- `Range` functions are in [`library/range.md`](../../site/content/library/range.md). `Range.size` is `RUNTIME-INTEGER-OVERFLOW` when the count does not fit in `Int`, and `Range.to_a` above 1048576 values is `RUNTIME-INVALID-COUNT`. `first` and `last` of an empty range are `error("the range is empty")`; unlike Ruby, `(1...5).last` is `ok(4)`.
- Ranges print as `1..5`. They are not JSON-encodable and cannot be `Map` keys. Ranges of `String` or `Float`, and `step`, are not supported.

### Maps

`Map[K, V]` has exactly two type arguments: `K` is `Int` or `String`, and `V` is any type.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- A literal uses braces and `key: value` pairs. An empty `{}` needs an expected type, like `[]`: `CHECK-EMPTY-MAP-TYPE` (`CHECK-EMPTY-LIST-TYPE` is for `[]`).
- `m[key]` returns the value; the key must have type `K`. A missing key is a runtime error.
- A repeated key in a literal keeps the last value at the first position. `Map.put` on an existing key keeps its position.
- Maps are immutable: there is no `m[key] = value`, and `Map.put` returns a new map. There is no map equality and no `for` over a map; iterate `Map.keys`, which is in insertion order.
- Lookup, `Map.has_key?` and `Map.put` take effectively constant time; `Map.keys` is O(n).

### Result and propagation

- `ok(value)`, `ok()` and `error(message)` build Results. `Result.Ok(x)`, `Result.Ok()` and `Result.Err(m)` are the same calls.
- `Result[T]` is builtin, not a user enum. It can nest and hold any payload. It has no equality, fields or indexing.
- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload against `T`, including empty lists and maps. `error("bad")` needs an expected Result type from an annotation, a binding, a parameter, a field, a return or a typed container element; otherwise it is `CHECK-RESULT-TYPE`. Container inference uses the first element, so `[ok(1), error("bad")]` infers and the reverse order needs an annotation.
- `Result.unwrap!` passes `Result[T]` to its operand. On an error it halts with `RUNTIME-UNWRAP-ERROR`, the stored message, at the call. `Result.unwrap_or` evaluates both arguments, left to right, even on success.
- `Result.ok?` and `Result.message` need a known Result type. A success's message is `""`. `ok(false)` and `ok(nil)` are successes. An error value never prints a diagnostic or changes the exit code. Non-bang String conversions return an error for bad text or overflow; other runtime failures are never turned into Results.
- `try` has unary precedence. It evaluates one `Result[T]` operand once: on success it gives `T`; on error it returns the error from the current function. Only a function that returns `Result[...]` may use it (`CHECK-TRY-CONTEXT` otherwise). An expected type `T` gives the operand `Result[T]`; the return type alone does not. A success still needs an explicit `return ok(...)`.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

### Function values

`f: Fn[Int, Int] = &double` refers to a declared function with exactly those types, and `f.call(21)` invokes it. Function values can travel through lists, maps, parameters, returns and fields. A bare function name is not a value. Functions have no equality, fields, indexing or JSON encoding; `IO.inspect` prints `<Fn>`.

### Blocks and closures

A block is a function written at the call site, as the last argument of a call:

```ruby
doubled = xs.map do |x|
  x * 2
end
total = xs.reduce(0) do |sum, x| sum + x end
```

- **Where.** `do |a, b| ... end` comes right after the `)` of a call, or after a method name without parentheses. The called function's last parameter must be a `Fn`; otherwise `CHECK-BLOCK-TARGET`, for user functions and builtins alike. A user function keeps its parentheses; only a function reached through an import alias may drop them (`Util.start do ... end`). `do || ... end` is rejected.
- **Headers.** `case`, `while` and `for` headers may end with an optional `do`, which is never a block; a block in such a header needs parentheses.
- **Parameter types** come from the expected `Fn` or the builtin's rule (`xs.map` gives `x` the element type), or from annotations such as `do |x: Int|`. With neither, `CHECK-BLOCK-TYPE`. A wrong number of parameters is `CHECK-ARITY`.
- **Result.** `return` leaves the block, not the function. Without `return`, the last expression statement is the value. For `map` and `sort_by` the result type comes from the body, where every `return` and the last expression must agree (`CHECK-TYPE-MISMATCH`). A non-`Void` block must return on every path (`CHECK-MISSING-RETURN`).
- **`try`** in a block returns the error from the block, so the block's result must be a `Result` (`CHECK-TRY-CONTEXT` otherwise). The result type must come from the call, so `try` is not available in `map` and `sort_by` blocks.
- **Capture by value.** A block sees the variables visible where it is written, with their values at creation; later outer assignments do not change it. Assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`; use `reduce` or a `for` loop. Block parameters and new variables cannot reuse a visible name (`CHECK-SHADOWED-NAME`).
- **Values.** A block has type `Fn[A, ..., R]` and works wherever a function value does, including as a BDD step. It shares the caller's step budget and call-depth limit. Blocks have no equality or JSON form.
