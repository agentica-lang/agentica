# Agentica language reference

Agentica is a small statically typed language with Ruby-like syntax. This file is the whole language: if a form is not here, it does not exist.

## Program shape

- A file has top-level `def`, `struct`, `enum`, and `import` declarations. Functions, structs, and enums may use `export`. No executable statements at the top level.
- The root file needs exactly one `def main() -> Void` with no parameters. Running a program calls only that entrypoint.
- Blocks end with `end`. Indentation is for reading only.
- `#` starts a comment that runs to the end of the line.
- Calls always use parentheses, even with no arguments: `main()`, `puts("hi")`.
- A newline ends a statement. Inside `(...)`, `[...]`, and `{...}` an expression may span lines, and a trailing comma is allowed. To split a long expression, wrap it in parentheses.
- Reserved words: `def struct enum case do import export end if elsif else while for in return try true false nil and or not`.
- Blank/comment lines each emit a newline token outside delimiters; extra newlines between statements/declarations are ignored.

Full programs are at the end of this file.

### File modules and imports

Each file is a module. Use `import "models.agc" as Models` at the top level.
Relative paths ending in .agc resolve from the importing file, not the working
directory. Canonical paths identify files; each file is linked once. Cycles and
missing/unreadable imports give located CHECK-IMPORT diagnostics.

`export struct User ... end`, `export enum Option[T] ... end`, and
`export def greet(...) ... end` expose declarations; everything else is
private. Use `Models.User` in annotations and JSON type arguments,
`Models.User(name: "Ana")` for construction, `Models.greet(user)` for calls,
and `&Models.greet` for callbacks. Imported enums use `Models.Option[T]`,
`Models.Option.Some(value)`, and `Models.Option.Some(item)` in patterns.
Local names remain unqualified inside their file. Import aliases are uppercase
and cannot collide with declarations, other aliases, or builtin names.
Imports cannot be re-exported. Exported signatures may mention private types,
but importers cannot name or construct those private types.

Only the root file supplies the executable `main() -> Void`. Imported main
functions do not run automatically. Linking preserves source spans and distinct
module identities; imported calls/tasks share the program's execution budget
and resource ownership. CLI check/run/dump and BDD handlers use the same loader.
There are no wildcard imports, package registry, module state, nested module
blocks, or receiver attachment. `as` is contextual in imports, not reserved.

#### Standard library and external libraries

All import paths end in `.agc`. Two prefixes select library resolution:

- `import "std/queue.agc" as Queue` loads the standard library embedded at
  build time. No stdlib installation, environment variable, or repository
  checkout is needed at runtime. Local files and external roots cannot shadow it.
- `import "pkg/acme/tools.agc" as Tools` searches for `acme/tools.agc` in:
  1. `agc_libs/` beside the root program (not beside each dependency or in cwd).
  2. Absolute roots in `AGENTICA_PATH`, in listed order.
  3. `$XDG_DATA_HOME/agentica/lib/`, defaulting to
     `~/.local/share/agentica/lib/`.
  4. `/usr/local/share/agentica/lib/`, then `/usr/share/agentica/lib/`.

On Windows, `AGENTICA_PATH` uses `;` instead of `:`, the user root is
`%LOCALAPPDATA%/agentica/lib/` (fallback `~/AppData/Local/agentica/lib/`),
and there are no default system roots. On other platforms the paths above apply.
An unset or relative user-data environment variable uses the fallback directory.
Empty `AGENTICA_PATH` entries are ignored; relative entries give
`CHECK-IMPORT-PATH` when resolving a `pkg/` import. First existing file wins;
a read or syntax error in that file does not fall back to another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash,
and colon components. External targets must remain inside their selected root
after symlink resolution. These restrictions apply to namespaced imports, not
to ordinary relative dependencies: imports are not a filesystem sandbox.
Missing modules give `CHECK-IMPORT-IO` at the import. Other imports retain
their existing file-relative behavior; there is no implicit search fallback.
Embedded-module diagnostics name their source, for example `std/queue.agc`.
Embedded dependencies may use relative paths within their stdlib directory.
External modules may use ordinary relative imports for their dependencies.

#### String queue

`std/queue.agc` is a non-native library written in Agentica. Its exported
immutable records are `QueueState(items: List[String])` and
`Popped(value: String, remaining: QueueState)`.

With the alias `Queue`:

```text
Queue.new() -> Queue.QueueState
Queue.push(q: Queue.QueueState, value: String) -> Queue.QueueState
Queue.pop(q: Queue.QueueState) -> Result[Queue.Popped]
Queue.peek(q: Queue.QueueState) -> Result[String]
Queue.size(q: Queue.QueueState) -> Int
Queue.empty?(q: Queue.QueueState) -> Bool
```

Push adds at the back; pop removes the oldest value. Empty pop/peek return an
error Result. Inputs remain unchanged; assign the returned queue (or
`Popped.remaining`) to continue. Empty strings and duplicates are valid.
QueueState is a normal exported struct, not an opaque handle. There are no
user generics or blocking cross-task queue operations.
The implementation uses Lists: push, pop, peek, size and empty? are O(n)
with the current host list operations; new is O(1). No constant-time FIFO
performance is promised.

## Types

| Type | Notes |
|---|---|
| `Int` | signed 64-bit; overflow is a runtime error |
| `Float` | IEEE 754 double |
| `Bool` | `true` / `false` only |
| `String` | Unicode text |
| `Nil` | the single data value `nil` |
| `Void` | completion without a usable value; no literal |
| `Process` | opaque child process; inspect prints `<Process>` |
| `List[T]` | homogeneous, immutable, indexed from 0 |
| `Map[K, V]` | homogeneous, immutable; `K` is `Int` or `String`; keeps insertion order |
| `Result[T]` | `ok(value)` or `error(message)`; the error is always String; exactly one type argument |
| `Option[T]` (example) | A user-defined generic enum; `Option` is not a builtin type |
| `Json` | opaque JSON value; use `JSON` functions to access it |
| `Fn[A, ..., R]` | named function value; last type is the return, preceding types are parameters; `Fn[Void]` takes no arguments |
| `Task[R]` | opaque lightweight task; exactly one result type |
| Network handles | opaque `Socket`, `Listener`, `HttpClient`, `HttpServer`, `HttpBody`, `HttpWriter` |
| Builtin records | `Header`, `Request`, `Response`, `HttpClientOptions`, `HttpServerOptions` |
| `Name` | a struct you declare; fields are typed and immutable |

Type names start with an uppercase letter. Variable, function, and field names start with a lowercase letter or `_`.


## Void completion

`Void` has no literal or usable payload. It is permitted as a function return, the final type of `Fn`, or the completion type of `Result`/`Task`. Bare Void variables, parameters, fields, List elements, and Map values are `CHECK-VOID-TYPE`. Wrappers such as `List[Result[Void]]` are valid data.

A Void call may be a statement or be forwarded from a Void function with return another_void_call(). Assignment, argument passing, construction, operators, and inspection of bare completion fail with CHECK-VOID-VALUE. The same restriction applies to Result.unwrap!(Result[Void]), Task.await(Task[Void]), and successful try on Result[Void].

ok() infers Result[Void] and prints ok(); ok(nil) is Result[Nil] and prints ok(nil). Result[Void] functions explicitly return ok() or error(message); try still requires an enclosing Result-returning function. Result.unwrap_or needs a data fallback and cannot operate on Result[Void].

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

def greet(user: User, times: Int) -> String
  return user.name
end
```

- Every parameter and the return type need an annotation.
- Structs, enums, and function declarations are top level only. Enum type parameters apply only to their payload types; generic functions and structs are not supported. There are no methods, closures, nested functions, default arguments, or overloading.
- Functions can be called before they are declared, and can be recursive.
- A function whose result is not `Void` must `return` on every path. A loop does not count as a return. The last expression is not returned implicitly.
- `return` alone and reaching the end complete a `Void` function. A `Nil` function explicitly returns `nil`.

## Statements

```ruby
count = 0              # new variable, type inferred (Int)
total: Float = 0.5     # new variable with an annotation
count = count + 1      # update: same name, same type

if count > 3
  puts("big")
elsif count > 1
  puts("medium")
else
  puts("small")
end

while count < 10
  count = count + 1
end

for item in items      # items is a List[T]; item is a new, read-only variable
  puts(item)
end

case option do
  Option.Some(value) -> IO.inspect(value)
  Option.None -> puts("empty")
end

return count
```

- The first assignment to a name creates it in the current block; later assignments change its value and cannot change its type.
- `x += e`, `-=`, `*=`, `/=`, `%=` mean `x = x op e`; `x` must already exist. Fields and indexes cannot be assigned.
- An annotation is only allowed when the variable is created.
- A name created in a block is not visible after that block's `end`.
- A new variable cannot reuse a name that is already visible in an outer scope (no shadowing).
- The `for` variable cannot be assigned to.
- `case value do pattern -> block end` is a statement. Each arm has a normal block and its bindings are local to that arm.
- Patterns are primitive literals, `_`, or qualified enum variants with one direct binding or `_` discard per payload position. Nested patterns and guards are not supported.
- Enum cases cover every variant or use `_`. Every non-enum case—including `Bool` and `Nil`—requires a top-level `_`. It must be the final arm; duplicate or unreachable arms are checker errors.
- `if` and `while` conditions must be `Bool`. There is no truthiness: `if 1` is an error.
- Assignment is a statement, not an expression. There is no `x[i] = v`, `x.f = v`, `break`, or `continue`.

## Expressions

- Literals: `42`, `3.14`, `"text"` (escapes `\" \\ \n \r \t`), `true`, `false`, `nil`. A minus sign is an operator, not part of the literal. There is no string interpolation: `"#{x}"` is plain text.
- Lists: `[1, 2, 3]`. Maps: `{"a": 1, "b": 2}` (a repeated key keeps the last value and its first-insertion position; `Map.put` replacement also keeps that position).
- An empty `[]` or `{}` needs a known type: an annotation, a parameter, a field, or the function result. A non-empty list needs elements of one type.
- Struct construction uses named fields, all of them exactly once, in any order: `User(name: "Ana", age: 25)`.
- Enum variants are qualified by their type. Construct payload variants positionally (`Option.Some("hi")`) and nullary variants with empty parentheses (`Option.None()`). Generic arguments are inferred from payloads and expected types; every type parameter must be known. A nullary generic variant therefore needs expected type context.
- Field access `user.name`; index `items[0]` and `stock["apple"]`. Strings cannot be indexed. List indexing is O(n); prefer `for` for traversal.
- Function call `f(a, b)` with positional arguments. Builtin module call `String.upcase(s)`. Method call on a builtin value `s.upcase`, `xs.map(&f)`: see "Methods on builtin types".
- `&name` references a declared top-level function, without capturing locals. `f: Fn[Int, Int] = &double`; call it with `f.call(21)`. Function values can be stored in containers, fields, parameters, and returns. Signatures must match exactly. Bare function names remain invalid as values. No lambdas, closures, equality, or JSON encoding; inspect prints `<Fn>`.

Operators, from highest to lowest precedence:

| Level | Operators |
|---|---|
| 1 | call, `.field`, `[index]`, `( )` |
| 2 | unary `-`, `not` / `!`, `try` |
| 3 | `*` `/` `%` |
| 4 | `+` `-` |
| 5 | `<` `<=` `>` `>=` |
| 6 | `==` `!=` |
| 7 | `and` / `&&` |
| 8 | `or` / `\|\|` |

- `+ - * /` take two numbers of the same type. There is no implicit conversion between `Int` and `Float`. `+` also joins two `String` values.
- `/` on `Int` truncates toward zero. `%` takes two `Int` values. A zero divisor is a runtime error, also for `Float`.
- `< <= > >=` take two numbers of the same type.
- `==` and `!=` take two values of the same primitive type (`Int`, `Float`, `Bool`, `String`, `Nil`). Lists, maps, structs, Results, Json and Fn values cannot be compared.
- Comparisons do not chain: write `a < b and b < c`, not `a < b < c`.
- `and`, `or`, `not` take `Bool`, and `and` / `or` short-circuit. `&&`, `||`, `!` are the same operators. `not` / `!` bind tightly: write `!(a >= b)`. A `!` right after a name is part of the name (`read!`).
- Arguments and operands are evaluated left to right.

## Builtin functions

`puts(value: String) -> Void` writes the text and a newline. The names `puts`, `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`, `Process`, `List`, `Map`, `Result`, `IO`, `System`, `Json`, `JSON`, `Fn`, `BDD`, `Task`, `File`, `Dir`, `Path`, `TCP`, `TLS`, `HTTP`, and the builtin types listed below are reserved. `ok` and `error` cannot be user function, local, parameter, loop-variable, or field declarations; they remain ordinary name tokens for calls.

```text
Map.has_key?(map: Map[K, V], key: K) -> Bool
Map.keys(map: Map[K, V]) -> List[K]            # insertion order
Map.size(map: Map[K, V]) -> Int
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]   # returns a new map
Map.get(map: Map[K, V], key: K) -> Result[V]
Map.get(map: Map[K, V], key: K, default: V) -> V
Map.delete(map: Map[K, V], key: K) -> Map[K, V]
Map.values(map: Map[K, V]) -> List[V]
List.size(list: List[T]) -> Int
List.append(list: List[T], value: T) -> List[T]
List.set(list: List[T], index: Int, value: T) -> List[T]
List.repeat(value: T, count: Int) -> List[T]
List.reverse(list: List[T]) -> List[T]
List.map(list: List[A], f: Fn[A, B]) -> List[B]
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B
List.concat(a: List[T], b: List[T]) -> List[T]
List.take(list: List[T], count: Int) -> List[T]
List.drop(list: List[T], count: Int) -> List[T]
List.at(list: List[T], index: Int) -> T
List.sort(list: List[T]) -> List[T]
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]

String.length(s: String) -> Int                # counts Unicode characters
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String
String.index_of(s: String, part: String) -> Result[Int]  # first match; error if absent
String.at(s: String, index: Int) -> String     # one character; halts outside
String.reverse(s: String) -> String
String.code(c: String) -> Int                  # code point; c must be one character
String.from_code(n: Int) -> String             # Unicode scalar value; halts otherwise
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.from_bytes(data: List[Int]) -> Result[String]  # strict UTF-8
String.to_int(s: String) -> Result[Int]
String.to_float(s: String) -> Result[Float]
String.to_int!(s: String) -> Int               # halts on bad text
String.to_float!(s: String) -> Float           # halts on bad text
Float.from_int(n: Int) -> Float
Float.to_int(x: Float) -> Result[Int]          # truncates; NaN, infinity, overflow are errors
Float.to_int!(x: Float) -> Int                 # truncates; halts on those

IO.puts(value: String) -> Void
IO.print(value: String) -> Void                 # no newline
IO.warn(value: String) -> Void                  # standard error
IO.inspect(value: T) -> T                      # prints a debug form, returns the value
IO.gets() -> Result[String]                   # ok(line) or error at EOF
IO.gets!() -> String                          # next line; halts at end of input
IO.read() -> String                          # drains until EOF
IO.read_bytes(count: Int) -> Result[List[Int]]
IO.flush() -> Void                            # flushes stdout only
IO.eof?() -> Bool                            # blocking byte peek, not readiness
System.args() -> List[String]
System.exit(code: Int) -> Void
Time.now_ms() -> Int                          # wall clock, ms since Unix epoch; may jump
Time.monotonic_ms() -> Int                    # never goes backward; use for durations
Random.int(min: Int, max: Int) -> Int         # uniform, both ends inclusive
Random.float() -> Float                       # uniform in 0.0 up to, not including, 1.0
```

`Time.now_ms()` reads wall-clock time as milliseconds since the Unix epoch; it can jump when the system clock changes. `Time.monotonic_ms()` counts milliseconds from an arbitrary origin and never goes backward; subtract two readings to measure durations. `Random.int(min, max)` returns a uniform `Int` in `min .. max`, both inclusive, over the whole `Int` range; `min > max` halts with `RUNTIME-INVALID-RANGE` at the call. `Random.float()` returns a uniform `Float` in `0.0` up to, but not including, `1.0`. Each run has its own generator. Without `--seed` it is seeded from operating-system randomness, so runs differ. `agentica --seed N program.agc` (N in `0 .. 2147483647`, otherwise exit 2) repeats the same sequence for the same program and input. `agentica --seed N test` passes the seed to step handlers and to the programs under test. Tasks share the run's generator, so the sequence each task sees depends on scheduling. The generator is not suitable for secrets. `Time` and `Random` are reserved builtin module names: no declaration or import alias may use them.

- A `?` or `!` suffix belongs to a function name regardless of whitespace before `(`: `String.contains? (a, b)`. `!` followed by `=` is not a suffix (`a!=b` means `a != b`). Variables, parameters, and fields cannot have these suffixes. By convention `?` means Bool and `!` halts on failure.
- Build lists with literals or `List.append`/`List.repeat`; update them with `List.set`. Concatenate lists with `List.concat`. To change a map, use `Map.put`/`Map.delete`; these operations leave the original unchanged.
- Map lookup, `Map.has_key?`, and `Map.put` use Racket immutable hashes and are effectively constant-time in map size (technically O(log n), excluding key hashing/comparison). `Map.size` is O(1); `Map.keys` is O(n). Updates share unchanged storage rather than copying the whole map.
- Reading a missing map key, an index outside `0 .. length - 1`, or a bad `String.slice` range is a runtime error.
- `String.index_of` and `String.at` count Unicode characters, like `String.length`. Use `String.code`/`String.from_code` for character arithmetic, and `Float.from_int`/`Float.to_int` to mix Int and Float; arithmetic never converts implicitly.

### Methods on builtin types

`receiver.name(args)` calls a builtin function with the receiver as its first argument. The checker picks the module from the receiver's static type, so there is no dynamic dispatch:

| Receiver type | Module |
|---|---|
| `String` | `String` |
| `List[T]` | `List` |
| `Map[K, V]` | `Map` |
| `Float` | `Float` |
| `Result[T]` | `Result` |
| `Json` | `JSON` |
| `Int` | aliases only |

Only functions whose first parameter has the receiver's type are methods: `s.trim` is `String.trim(s)`, `xs.map(&f)` is `List.map(xs, &f)`, but `"a".from_int` is not a method. Without parentheses, `receiver.name` on a non-struct value is a method with no arguments: `s.length`, `xs.size`, `r.ok?`. On a struct, `.name` is field access; structs and enums have no methods, and user functions cannot be called as methods. `.call(...)` invokes a function value.

Ruby aliases:

| Receiver | Alias | Same as |
|---|---|---|
| `String` | `size` | `String.length` |
| `String` | `to_i`, `to_i!` | `String.to_int` (Result), `String.to_int!` |
| `String` | `to_f`, `to_f!` | `String.to_float` (Result), `String.to_float!` |
| `String` | `strip` | `String.trim` |
| `String` | `include?`, `start_with?`, `end_with?` | `String.contains?`, `String.starts_with?`, `String.ends_with?` |
| `String` | `to_s` | the same string |
| `List` | `length` | `List.size` |
| `List` | `push` | `List.append` |
| `List[String]` | `join` | `String.join` |
| `Int` | `to_s`, `to_f` | `String.from_int`, `Float.from_int` |
| `Float` | `to_s` | `String.from_float` |
| `Float` | `to_i`, `to_i!` | `Float.to_int` (Result), `Float.to_int!` |

Unlike Ruby, `"abc".to_i` returns `Result[Int]` (an error here), not `0`; `to_i!` halts on bad text. An unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the list of that type's methods.

Values are immutable, so a method never changes its receiver: `xs.push(2)` returns a new list. Calling a builtin without effects and ignoring a non-`Void` result is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Functions ending in `!` are exempt, since they can halt.

```ruby
words = line.strip.split(" ")
puts(words.join(","))
first = words[0].to_i!
xs = xs.push(first)
```

### Collections

`List.map` transforms each element; `List.filter` keeps elements whose predicate returns true. Both preserve order and inputs. `List.reduce` folds left, calling `f(accumulator, item)` with the initial value first; an empty list returns the initial value. Callbacks run exactly once per element, left to right, and use the caller's execution budget and error handling. Callback parameter and return types must match exactly; map callbacks must return data, not Void. Callback signatures infer empty input lists and empty reduce initial values. All three operations cost O(n), excluding callback work. Pass a named function reference (`&name`) or a function-valued variable; there are no closures.

`List.concat` joins lists of the same element type in O(length of the first list). `List.take` returns the first count elements; `List.drop` removes them. Nonnegative counts above length return the whole list or empty list, respectively; negative counts halt with `RUNTIME-INVALID-COUNT` at the count argument. Both cost O(n). `List.at` reads a zero-based index in O(n); negative or out-of-range indexes halt with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument.

`List.sort` sorts in ascending order; its elements must be `Int`, `Float`, or `String`. `List.sort_by` sorts by the key its function returns, and the key must be `Int`, `Float`, or `String`. The key function runs once per element, left to right. Both sorts are stable: equal elements keep their order. Strings compare by Unicode code point, so `"B"` comes before `"a"`. Float NaN goes last. Other element or key types are `CHECK-TYPE-MISMATCH`. Both cost O(n log n), plus the key calls, and preserve the input.

All collection updates preserve their inputs. `List.append`, `List.set`, and `List.reverse` cost O(n); repeated appends cost O(n²). Indexing is still O(n). `List.repeat` costs O(count) and accepts 0..1048576; zero returns an empty list of the inferred element type, and invalid counts halt with `RUNTIME-INVALID-COUNT` at the count argument. `List.set` requires an index in 0..length-1; otherwise it halts with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument. Expected types support empty collections and Result elements; annotate when there is insufficient context.

`Map.get(map, key)` returns `Result[V]`: `ok(value)` if present, `error(message)` if missing. `Map.get(map, key, default)` returns V and eagerly evaluates the default even when the key exists. False and nil are present values. `Map.delete` ignores absent keys, preserves remaining insertion order, and costs O(n); reinsertion adds the key at the end. `Map.values` costs O(n) and follows `Map.keys` order.

`agentica help Map.get` and `agentica help HTTP.client` show their signatures. Their JSON help contains `overloads`, with one entry per arity. Other builtin JSON help retains the single-signature format.

### Counted input and flushing

- `IO.read_bytes(count)` waits for count bytes or EOF; it returns integers in `0 .. 255`, not decoded text. Short final reads succeed, EOF before any bytes is `ok([])`, and zero returns `ok([])` without consuming input. Count must be `0 .. 1048576` (1 MiB); invalid counts return an error without consuming input. Input-port failures also return an error. Process larger streams in multiple reads.
- `String.from_bytes` validates byte values and decodes UTF-8 strictly. Empty input succeeds with `""`; invalid, overlong, surrogate, and incomplete sequences return errors, never replacement characters. A byte read can split a UTF-8 character; decode only complete sequences. Text and byte reads share the same port, so switch to text reads only at character boundaries.
- `IO.eof?()` peeks without consuming the next byte. It may block until a byte or EOF arrives; it does not wait for a complete UTF-8 character and is not a readiness poll. Reads have no timeout; step budgets do not interrupt blocking I/O.
- `IO.read()` waits for EOF, so use `IO.gets()` for line-delimited live protocols. `IO.flush()` flushes stdout without closing it; it does not flush stderr. Output calls do not auto-flush. For MCP stdio, put one compact JSON message on each line, flush after each response, and send logs to `IO.warn`.

```ruby
def main() -> Void
  data = IO.read_bytes(4)
  if Result.ok?(data)
    text = String.from_bytes(Result.unwrap!(data))
    IO.print(Result.unwrap_or(text, "invalid UTF-8"))
    IO.flush()
  end
end
```

## Result and try

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String
```

- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload against T, even for `ok([])` or `ok({})`.
- `error("bad")` needs an expected Result type from an annotation, an existing binding, a return, argument, field, or typed container element. `r = error("bad")` alone is `CHECK-RESULT-TYPE`; write `r: Result[Int] = error("bad")`.
- `Result.unwrap!` passes its expected output T into the operand as `Result[T]`; errors halt with `RUNTIME-UNWRAP-ERROR` at that call. `Result.unwrap_or` uses expected T or infers it from the default; both arguments always run left to right, even on success.
- `Result.ok?` and `Result.message` require a known Result argument; they cannot infer a bare error's payload type. `Result.message` is the stored error message or `""` for a success.
- `ok(false)` and `ok(nil)` are successes. Results can nest and contain lists/maps/structs; they have no equality, direct fields, or indexing. `IO.inspect` prints recursive `ok(...)` / `error(...)` forms and returns its argument.
- Lists/maps still infer from the first element. `[ok(1), error("bad")]` infers; the reverse order needs an annotation.
- Non-bang conversions use the same signed-decimal syntax and 64-bit integer bounds as bang forms, but invalid text/overflow return errors. `IO.gets` returns a line without LF/CR/CRLF; a blank line is `ok("")`, not EOF. Unrelated runtime errors are not converted to Results.
- Match builtin Results with `Result.Ok(value)` and `Result.Err(message)`; constructors remain `ok` and `error`. `Result.Ok(_)` discards the payload and supports `Result[Void]` without binding a Void value.
- `try` evaluates its Result operand once: success produces the payload; an error returns from the current function. Only a function returning Result may use it, but operand and enclosing success types may differ. It binds like unary `not`; use parentheses for a larger operand. Expected output T supplies `Result[T]` to the operand; the function return type alone does not infer that payload. Success paths still need explicit returns.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end

def main() -> Void
  age = read_age("bad")
  if not Result.ok?(age)
    puts(Result.message(age))
  end
  puts(String.from_int(Result.unwrap_or(age, 0)))
end
```

`agentica help NAME --json` describes a builtin's signature, parameters, arity, effects, and behavior without a program file. Unknown names exit 2. Effects are informational, not permissions.

`agentica --max-steps N program.agc` limits execution to N expression/statement entries, counting repeated loop conditions across all tasks and nested tasks. N must be positive; runs are unlimited by default. Exhaustion is `RUNTIME-STEP-LIMIT`, the synchronized counter resets each evaluation, and checking never spends steps. This is not a blocking-I/O timeout.

## Lightweight tasks

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Void
```

Start tasks before awaiting them to overlap I/O. They call named functions with one argument; pass a struct for multiple values. Each has independent variables, scopes and returns. Await returns the cached value and can be repeated. False, nil and error Results are normal values, with no extra Result wrapper. Task[R] has no constructor, equality, fields, indexing or JSON encoding; inspect prints `<Task>`. A handle belongs to its execution; awaiting one in another halts with RUNTIME-TASK-CONTEXT.

Any task diagnostic terminates the evaluation with its original code and span, even when unawaited. System.exit in any task terminates that evaluation with its code. The first terminal outcome published by the supervisor wins. Returning from the entrypoint cancels pending work; explicitly await tasks that must finish. External interruption cancels tasks and closes newly created resources while preserving caller-supplied ports. No channels, closures or CPU parallelism are exposed.

Sleep accepts nonnegative milliseconds; zero yields and negative values halt with RUNTIME-INVALID-DURATION at the argument. Tasks inherit ports, program arguments and contextual services. Cross-task output order is unspecified; coordinate ownership of reads.

```ruby
def double(n: Int) -> Int
  Task.sleep(0)
  return n * 2
end

def main() -> Void
  first = Task.spawn(&double, 21)
  second = Task.spawn(&double, 7)
  puts(String.from_int(Task.await(first)))
  puts(String.from_int(Task.await(second)))
end
```

BDD registration and steps may spawn tasks. Finish them before returning, normally by awaiting them; pending work fails with RUNTIME-BDD-PENDING-TASKS. Child failures stop only their current handler; later scenarios continue. Completed child assertions count toward the current Then step; Doc Strings and tables remain those of that step. BDD registration/state/assertions are synchronized and stream lock wait counts against the operation timeout.


## Processes

Process is an opaque handle with no constructor, fields, equality, or JSON encoding. IO.inspect prints <Process>.

~~~text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
~~~

- Launching requires agentica --allow-run file.agc. The flag defaults off and precedes the source file; later arguments reach System.args. The test command accepts it before or after the command. Checking and builtin help need no flag. Permission reaches tasks, HTTP callbacks, BDD handlers, and programs started by BDD. The existing BDD runner can still launch its programs without granting them Process.spawn.
- Commands resolve through PATH or an explicit path relative to the inherited working directory. Children inherit the environment. Arguments are passed directly without shell interpolation. Empty commands, NUL-containing arguments, unavailable executables, and Windows batch commands fail. OS execution failure after creation may appear as stderr and a nonzero child exit.
- Timeouts are positive milliseconds, including lock wait. Read and write locks are independent. A timeout after starting stream I/O kills and closes the child; timing out while waiting for its lock preserves it. Waiting for exit times out without terminating the child.
- Sends accept at most 1048576 UTF-8 bytes or integers 0..255 and flush before succeeding. Invalid data consumes nothing. read_bytes accepts 0..1048576 and waits for that count or EOF: short/empty EOF succeeds, and zero consumes nothing.
- read_line consumes a line of at most 1 MiB, strips LF/CRLF, and strictly decodes UTF-8. An unterminated final line succeeds; empty EOF is an error. Invalid UTF-8 consumes the completed line. An oversized line closes the child.
- close_stdin flushes and closes input idempotently; further sends fail. wait returns the host exit code, including nonzero codes, and can be repeated. It preserves unread stdout and waits for stderr forwarding to finish.
- Stderr streams separately to the evaluation's error port with a fixed-size buffer. Output has no lifetime cap. A child can block when stdout's pipe fills: use Task to read concurrently with sending or waiting.
- Handles belong to their evaluation. close force-kills a running child, reaps it, closes owned ports/workers, and is idempotent. Other operations on closed handles fail. Main return, System.exit, diagnostics, task failures, step exhaustion, and external interruption also clean up directly spawned children. Arbitrary descendant trees are outside the cleanup guarantee. Borrowed ports remain open.
- Operational failures return String error Results. Cross-evaluation access is RUNTIME-PROCESS-CONTEXT; explicit cleanup failures are RUNTIME-PROCESS-CLOSE, at the call span.

## Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
reject directories and special files.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.read_text(path: String, timeout_ms: Int) -> Result[String]
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Void]
Path.cwd() -> Result[String]
Path.join(parts: List[String]) -> Result[String]
Path.resolve(path: String) -> Result[String]
```

Modes are `read`, `write` and `append`: read requires an existing regular
file; write creates or truncates; append creates or appends. Text is strict
UTF-8. Whole-text helpers and each stream read/write are limited to 1 MiB;
`read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF. `read_line`
removes LF or CRLF, accepts a final unterminated line, and returns an error
for EOF before any line or invalid UTF-8. Byte values are 0..255. Close
flushes output and is idempotent. Explicit flush and close return Results.

Timeouts are positive milliseconds and include the serialized handle lock
wait. Timing out active I/O closes that handle; timing out while waiting for
its lock leaves it open. Errors are Results. `File.stat` follows symlinks and
returns `FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`;
directory sizes are zero. `Dir.list` returns immediate entry names sorted by
name. `Dir.mkdir` creates parents and succeeds when the directory exists.
`Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path
without resolving symlinks.

## TCP, TLS and HTTP/1.1

Networking uses the existing expression syntax and lightweight Racket tasks.
`TCP`, `TLS`, `HTTP`, `Socket`, `Listener`, `HttpClient`, `HttpServer`,
`HttpBody`, `HttpWriter`, `Header`, `Request`, `Response`,
`HttpClientOptions` and `HttpServerOptions` are reserved. Handles are opaque:
no constructor, equality, fields or JSON encoding; inspect prints their type
in angle brackets. Handles belong to their evaluation and close when it ends.
Network access needs no CLI permission flag.

```text
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[Socket]
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.accept(listener: Listener, timeout_ms: Int) -> Result[Socket]
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.send_bytes(socket: Socket, bytes: List[Int], timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
TCP.local_port(listener: Listener) -> Int
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

Listen on port zero for an assigned port. TLS listeners and sockets use the
same TCP operations. TLS verifies certificates and hostnames with TLS 1.2 or
later; an empty CA path uses system trust, a nonempty path selects a PEM CA.
The server takes a PEM certificate chain and private key.

Timeouts are positive milliseconds and cover the whole operation, including
lock waits. Read and write directions have independent locks; coordinate
which task reads a stream and the order of writes. Timing out an active I/O
operation closes that socket. Waiting for a lock alone does not close it.
Failures return Results; explicit close is idempotent.

Send encodes UTF-8 and flushes. Byte values must be 0..255, at most 1 MiB per
send_bytes call. recv_bytes accepts 1..1048576, returns available data up to
that count, and returns ok([]) at EOF. TCP supplies a stream, not messages.
read_line handles fragmented UTF-8, strips LF or CRLF, accepts a final line
without a terminator, and errors on empty EOF or a line over 1 MiB.

Builtin records are immutable and use the existing named-field constructors:

| Record | Fields |
| --- | --- |
| Header | name: String, value: String |
| Request | method: String, target: String, path: String, headers: List[Header], body: HttpBody |
| Response | status: Int, headers: List[Header], body: HttpBody |
| HttpClientOptions | timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String |
| HttpServerOptions | header_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int |

Request.target preserves the origin-form target including the query; path is
the part before `?`, with no percent decoding. Incoming header names are
lowercase. Lists preserve duplicates and order, including Set-Cookie.
Header values use the HTTP Latin-1 byte range; names must be HTTP tokens.
CR/LF injection, control characters and user-supplied framing headers are
rejected. Host is supplied by the client; Content-Length and Transfer-Encoding
are supplied by framing operations.

```text
HTTP.client_options() -> HttpClientOptions
HTTP.server_options() -> HttpServerOptions
HTTP.client() -> Result[HttpClient]
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[Response]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request_stream(client: HttpClient, method: String, url: String, headers: List[Header], length: Int, producer: Fn[A, HttpWriter, Result[Void]], argument: A) -> Result[Response]
HTTP.read(body: HttpBody, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
HTTP.text(body: HttpBody, timeout_ms: Int) -> Result[String]
HTTP.trailers(body: HttpBody) -> Result[List[Header]]
HTTP.close_body(body: HttpBody) -> Void
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

Options helpers return defaults: 30 s operation/header timeout, 30 s idle
timeout, 4 connections per client origin or 128 server connections, 64 MiB per
body, and system CA trust. Construct options records to customize them; numeric
options must be positive, and max_connections is capped at 65536.
Request acquisition, DNS, connection, TLS and response headers share one
client timeout. HTTP.wait deliberately waits until explicit close.

The pool groups connections by scheme, hostname and port. Each connection has
one active exchange. Reuse requires complete upload and complete response
consumption, including chunk terminators and trailers. Connection: close,
EOF-framed bodies, invalid framing, or abandoned bodies prevent reuse.
Closing a client closes its pool and active exchanges. A pending pool wait
may time out without affecting another exchange.

get/post/request return as soon as response headers are available. HTTP 4xx
and 5xx are normal Response values. request_stream runs a supervised producer
concurrently with response reception; length -1 uses chunked, otherwise it is
the exact byte length. Pass producer data through argument; no closures are
needed. The producer can finish with trailers; otherwise successful return
finishes automatically. An error Result aborts the exchange and appears on
the request or a subsequent body read. Producer diagnostics terminate the
evaluation with their original location.

read accepts 1..1048576 bytes and returns progress, not an entire requested
buffer. ok([]) means body EOF. text collects up to 1 MiB within one total
deadline and decodes UTF-8 strictly. Decode arbitrary streamed chunks only
after assembling complete characters. trailers requires completed consumption;
close_body abandons an unread body. Header lookup is case-insensitive.
Content encoding remains raw: there is no automatic gzip decompression.

```text
HTTP.listen(host: String, port: Int, handler: Fn[Request, HttpWriter, Void], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[Request, HttpWriter, Void], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
HTTP.begin(writer: HttpWriter, status: Int, headers: List[Header], length: Int, timeout_ms: Int) -> Result[Void]
HTTP.write(writer: HttpWriter, text: String, timeout_ms: Int) -> Result[Void]
HTTP.write_bytes(writer: HttpWriter, bytes: List[Int], timeout_ms: Int) -> Result[Void]
HTTP.finish(writer: HttpWriter, trailers: List[Header], timeout_ms: Int) -> Result[Void]
HTTP.respond(writer: HttpWriter, status: Int, headers: List[Header], text: String, timeout_ms: Int) -> Result[Void]
```

Connections run concurrently with independent evaluator contexts and one
shared step budget. Each connection processes requests sequentially. begin
starts a response with status 200..599; length -1 selects chunked. write and
write_bytes flush each part, at most 1 MiB per call. Fixed lengths must match
exactly. finish emits the final chunk/trailers or validates a fixed length.
respond combines begin/write/finish for a UTF-8 string.

HEAD suppresses response bytes; 204 and 304 have no response body. The server
supports 100 Continue and rejects unsupported expectations. It finishes a
valid response on handler return; a handler that never begins a response
gets 500 and connection close. Unconsumed request bodies close the connection.
Writers become inactive on handler/producer return. Coordinate ownership:
immutable records do not make socket operations atomic across tasks.

close_server stops acceptance, cancels handlers and nested tasks, closes all
connections and wakes wait. It is idempotent. Main return and global failure
also close services. An awaited task cancelled by resource shutdown reports
RUNTIME-TASK-CANCELLED; intentional shutdown itself is not a global failure.
BDD handlers must close services and finish tasks before returning.

HTTP/1.1 supports fixed lengths, chunked transfer, trailers and informational
responses. Ambiguous framing is rejected. Header limits are 64 KiB, 100
entries and 8 KiB per line. Body limits apply incrementally. Protocol errors
before dispatch affect only their connection; body read failures return Results.
A handler's explicit unwrap failure remains a global diagnostic.
HTTP/1.0, upgrades, proxies, automatic redirects/retries, cookie management and
a dedicated SSE API are outside this phase.

## BDD feature specifications

`agentica test [PATH...] [--steps FILE] [--ai|--json]` executes `.feature` files, recursively searching directories in sorted order; default path is `specs/`. `--steps` is repeatable and loads explicit `.agc` handlers. Empty discovery fails. Exit codes: 0 all pass, 1 verification fails, 2 infrastructure/usage fails. Programs under test run as local processes. Use `make exe` to build the CLI or run `racket src/main.rkt test ...` directly; `make test` includes process integration tests and `make test-bdd` checks the compiled CLI against the feature suite. `make test JOBS=N` controls parallel test workers.

English syntax: `Feature`, one optional `Background` before scenarios, `Scenario`/`Example`, `Scenario Outline` plus `Examples`, and `Given`/`When`/`Then`/`And`/`But`. Each Examples row becomes a scenario, substituting `<column>` in names, steps, Doc Strings and tables. Comments, tags and descriptions before steps are accepted. Tags never skip tests. `Rule`, `*`, other keyword aliases and localized syntax fail explicitly. `And`/`But` inherit the previous kind. Triple-quote Doc Strings are dedented; include a final empty line to retain a trailing newline. Data Tables decode `\|`, `\\`, `\n`. One argument per step.

Predefined step patterns (keyword is irrelevant for matching):

| Text | Argument |
| --- | --- |
| `the Agentica program {string}` | candidate `.agc` path relative to the feature |
| `I send a line:` | Doc String, then LF and flush |
| `I send the line {string}` | quoted text, then LF and flush |
| `I send input:` | literal Doc String and flush |
| `I close stdin` | EOF |
| `I receive a line within {int} milliseconds:` | expected Doc String |
| `I receive the line {string} within {int} milliseconds` | expected quoted text |
| `I receive a JSON line within {int} milliseconds:` | expected JSON Doc String; object key order ignored |
| `stdin remains open` | input open and program active |
| `the program exits with code {int} within {int} milliseconds` | wait and check exit code |
| `stdout is:` / `stderr is:` | complete Doc String after exit |

Custom handler files register in `main() -> Void`: `BDD.step("I submit a record:", &submit)`. `submit(args: List[String]) -> Void` can use `BDD.when_line(BDD.doc_string())`. Patterns are literal text plus `{string}` and `{int}`; unknown captures and duplicate/ambiguous patterns fail. Captures are strings in order; quoted strings lose delimiters and unescape backslash-prefixed characters. Decimal integers may have a minus sign.

```text
BDD.run(feature_path: String, step_files: List[String]) -> Result[Json]
BDD.step(pattern: String, handler: Fn[List[String], Void]) -> Void
BDD.doc_string() -> String
BDD.table() -> List[List[String]]
BDD.assert(condition: Bool, message: String) -> Void
BDD.set(name: String, value: Json) -> Void
BDD.get(name: String) -> Result[Json]
BDD.given_program(path: String) -> Void
BDD.when_line(text: String) -> Void
BDD.when_input(text: String) -> Void
BDD.when_eof() -> Void
BDD.then_line(expected: String, timeout_ms: Int) -> Void
BDD.then_json_line(expected: String, timeout_ms: Int) -> Void
BDD.then_stdin_open() -> Void
BDD.then_exit(code: Int, timeout_ms: Int) -> Void
BDD.then_stdout(expected: String) -> Void
BDD.then_stderr(expected: String) -> Void
```

`BDD.run` accepts a file or directory. An infrastructure failure returns an error Result. A completed evaluation returns JSON containing `ok`, `passed`, `failed`, `not_executed`, `file_errors`, `exit_code`, and detailed `files`. A successful Result can contain failed tests: inspect `JSON.bool(Result.unwrap!(JSON.get(report, "ok")))` and choose `System.exit(1)` when false. The CLI enforces this automatically. `BDD.run` is unavailable recursively inside handlers.

Only registration permits `BDD.step`; actions/state/assertions require a running scenario. Missing Doc Strings/tables halt; absent state returns an error Result. Every `Then` (including its And/But) must perform a BDD assertion. Premature System.exit, even zero, fails. Failure stops only that scenario's remaining steps, marked `not_executed`; other scenarios/files continue. Each scenario starts with empty state and a fresh local process, executing Background again. Programs run with host permissions and environment, with the feature directory as their working directory; BDD provides no filesystem or network isolation. Timeouts are positive; each scenario has 30 seconds, operations without explicit deadlines 5 seconds, each callback one million evaluator steps, each stream 1 MiB. Scenario cleanup terminates processes and closes their ports on all outcomes.

## JSON

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(value: Json) -> Bool
JSON.schema(type: T) -> Json
JSON.decode(s: String, type: T) -> Result[T]
JSON.parse(s: String) -> Result[Json]
JSON.encode(value: T) -> String
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
JSON.list(j: Json) -> Result[List[Json]]
```


JSON builders create Json values directly: object takes Map[String, Json],
array takes List[Json], and from accepts the same recursively encodable data
as JSON.encode. Non-finite Float conversion halts with RUNTIME-JSON-ENCODE.
Null and false remain distinct, as do empty objects and arrays.

JSON.schema(User) accepts the same named structs as JSON.decode and returns
an object schema with properties and required fields. Int schemas specify
signed 64-bit bounds; lists use items and String-keyed maps use
additionalProperties. Nested/recursive structs use $defs/$ref. Extra struct
keys remain allowed, matching decoding. Schema is a Json value, not text.

`JSON.decode(text, User)` returns Result[User]. Its second argument is a named
struct type, not a runtime value; bare type names are valid only for decode/schema.
Fields may contain Int, Float, Bool, String, lists, String-keyed maps, and nested
or recursive structs. Unsupported nested types give CHECK-NOT-DECODABLE.
Malformed JSON, missing fields, wrong types, Int overflow, or non-finite Float
conversion return errors with field/index paths. Extra object keys are ignored.
Integer JSON values may decode as Float; decimal/exponent values never decode
as Int. Maps decoded from JSON use sorted key order.


- Json is opaque: no constructor, equality, fields, or `j[key]` / `j[index]`. `IO.inspect` prints `<Json>`; `JSON.encode` prints its JSON contents.
- Parse requires exactly one JSON value, with optional surrounding space/tab/CR/LF. Empty input, malformed JSON, trailing content, bad Unicode escapes, raw control characters in strings, and non-finite parsed numbers return errors. Repeated object keys keep the last value.
- Get requires an object and a present key; at requires an array and a nonnegative index smaller than its length. Wrong kinds, missing keys, and bad indexes return errors. JSON false and null are present values, not missing-key sentinels.
- String/Bool extraction requires that exact kind. Int extraction requires a signed 64-bit integer; `1.0` and `1e0` are not Int. Float extraction accepts integers and decimal/exponent numbers, with normal binary64 rounding, and rejects conversion overflow. Parsed integers may exceed Int bounds until extracted.
- List extraction returns array elements as Json values, including heterogeneous arrays. Null stays inside Json; there is no null extractor yet.
- Encode accepts Int, Float, Bool, String, Nil (as null), Json, lists, String-keyed maps, and structs, recursively. Results and Int-keyed maps are `CHECK-NOT-ENCODABLE`, even if empty or nested. Empty literals still need a known type.
- Encoding is compact; structs follow declaration order, maps follow insertion order. Parsed Json object order is unspecified. Non-finite Floats halt with `RUNTIME-JSON-ENCODE` at the encode call.

### Prefer structs for fixed JSON shapes

Struct fields may have different types, while maps/lists are homogeneous.
For protocol envelopes, declare the shape and encode the struct directly rather
than building a `Map[String, Json]` and wrapping every scalar with `JSON.from`:

```ruby
struct RpcResponse
  jsonrpc: String
  id: Json
  result: Json
end

def reply(id: Json, result: Json) -> Void
  response = RpcResponse(jsonrpc: "2.0", id: id, result: result)
  puts(JSON.encode(response))
  IO.flush()
end
```

Use separate message shapes so only the appropriate fields are emitted.
`ok` and `error` are reserved field names, so a JSON-RPC error envelope cannot
be a struct: use a String-keyed map for that envelope and a typed struct for
its nested code/message payload. Give fixed nested records native typed fields too; retain
`Json` for variable payloads or identifiers and use `JSON.from(payload)` once
at that boundary. `JSON.encode` accepts structs and String-keyed maps directly;
`JSON.object` is not required before encoding. Use builders for dynamic object
shapes or heterogeneous JSON arrays, where the `Json` wrappers are useful.
For a shared stdio transport helper, accept encoded `String`, print it and flush;
there are no user generics or structural unions to accept arbitrary structs.

```ruby
def greet_json(text: String) -> Result[String]
  root = try JSON.parse(text)
  member = try JSON.get(root, "name")
  name = try JSON.string(member)
  return ok("hello, " + name)
end

def main() -> Void
  text = JSON.encode({"name": "Ana"})
  puts(Result.unwrap!(greet_json(text)))
end
```

## Diagnostics

`CHECK-VOID-TYPE` rejects Void in a data type position; `CHECK-VOID-VALUE` rejects using completion as data. Process ownership and explicit cleanup diagnostics are `RUNTIME-PROCESS-CONTEXT` and `RUNTIME-PROCESS-CLOSE` at the call span. Expected process failures return error Results.

A failure prints to stderr and exits 1 (the run stops at the first error):

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The code prefix is the stage: `LEX-` (characters), `PARSE-` (syntax), `CHECK-` (names and types, before running), `RUNTIME-` (while running).

| Code | Meaning |
|---|---|
| `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER` | bad character, string, or bracket |
| `PARSE-UNEXPECTED-TOKEN` | the parser expected something else here |
| `PARSE-UNCLOSED-BLOCK` | missing `end` |
| `PARSE-TOP-LEVEL-STATEMENT` | a statement outside a function |
| `PARSE-CHAINED-COMPARISON` | `a < b < c` |
| `PARSE-INVALID-ASSIGNMENT-TARGET` | assignment to an index or field |
| `CHECK-TYPE-MISMATCH` | a value, operand, condition, argument, or return has the wrong type |
| `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD` | a name, type, or field that does not exist |
| `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING` | duplicate declaration, shadowing, annotation on an existing name |
| `CHECK-ARITY` | wrong number of arguments |
| `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD` | struct construction fields |
| `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE` | an empty `[]` or `{}`, respectively, with no expected type |
| `CHECK-RESULT-TYPE` | an error constructor without an expected Result type |
| `CHECK-TRY-CONTEXT` | try in a function not returning Result |
| `CHECK-MISSING-RETURN` | a path without `return` in a non-`Void` function |
| `CHECK-MAIN` | missing or wrong `main` |
| `CHECK-NOT-A-STRUCT`, `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST` | field access on a non-struct, index on a non-list/map, `for` over a non-list |
| `CHECK-MAP-KEY-TYPE` | a map key that is not `Int` or `String` |
| `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`, `CHECK-IMPORT-NAME` | Missing/unreadable import, invalid path, cycle, or unknown/private imported name |
| `CHECK-MODULE-CONTEXT` | Raw import/export declarations need module resolution before checking |
| `CHECK-NOT-DECODABLE` | JSON.decode/schema target is not a struct or contains unsupported field types |
| `CHECK-NOT-ENCODABLE` | JSON.encode on a type with unsupported nested values or Int-keyed maps |
| `CHECK-IMMUTABLE-ASSIGNMENT` | assignment to a `for` variable |
| `CHECK-INT-RANGE` | an integer literal that does not fit in `Int` |
| `CHECK-UNKNOWN-METHOD` | method not defined for the receiver's type, or a method call on a struct |
| `CHECK-UNUSED-VALUE` | result of a builtin without effects is ignored (`xs.push(1)` alone) |
| `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW` | arithmetic failure |
| `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND` | list index or map key not present |
| `RUNTIME-INVALID-COUNT` | List.repeat count outside 0..1048576, or negative List.take/drop count |
| `RUNTIME-INVALID-NUMBER` | `String.to_int!` / `String.to_float!` on bad text, `Float.to_int!` on NaN or infinity |
| `RUNTIME-INVALID-RANGE` | `Random.int` with `min > max` |
| `RUNTIME-INVALID-CHARACTER` | `String.code` without exactly one character, or `String.from_code` outside Unicode scalar values |
| `RUNTIME-END-OF-INPUT` | `IO.gets!` with no input left |
| `RUNTIME-UNWRAP-ERROR` | Result.unwrap! on an error |
| `RUNTIME-JSON-ENCODE` | JSON.encode cannot represent a non-finite Float |
| `RUNTIME-STEP-LIMIT` | execution step budget exhausted |
| `RUNTIME-STACK-OVERFLOW` | recursion too deep |

## Complete programs

Control flow and functions:

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Void
  puts(classify(25))
end
```

Structs and lists:

```ruby
struct Todo
  title: String
  done: Bool
end

def main() -> Void
  tasks: List[Todo] = [
    Todo(title: "write code", done: false),
    Todo(title: "review code", done: true)
  ]

  for task in tasks
    if not task.done
      puts(task.title)
    end
  end
end
```

Maps and strings:

```ruby
def main() -> Void
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = Map.put(stock, "kiwi", 7)
  for name in Map.keys(stock)
    if stock[name] > 0
      puts(String.upcase(name) + ": " + String.from_int(stock[name]))
    end
  end
end
```
