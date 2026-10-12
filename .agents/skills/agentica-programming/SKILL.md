---
name: agentica-programming
description: Write, check, run, and repair Agentica programs (`.agc` files). Use for Agentica application code; use agentica-development for interpreter, tests, or language implementation changes.
---

# Agentica programming

Agentica is Ruby with static types: Ruby-like syntax, checked before running, with immutable values. This file holds the core language; the files in `references/` hold the rest. If a form is in none of them, it does not exist: do not guess syntax or APIs.

## Write and verify

1. Save the requested program as a `.agc` file. It needs one `main() -> Void`.
2. Check and run it with `agentica program.agc`; it runs on the bytecode VM, and a program that uses `TCP`, `TLS`, `HTTP` or `BDD` runs on the older evaluator after one notice line on stderr. Use `agentica check program.agc` for check-only, or `agentica --dump program.agc` to inspect the checked tree. `agentica compile program.agc -o program.agcb` writes bytecode for `agentica-vm` and `--dump-ir` prints the lowered IR; both report `LOWER-UNSUPPORTED` for `TCP`, `TLS`, `HTTP` and `BDD`.
3. Fix diagnostics and rerun. Exit `1` means a program diagnostic; exit `2` means bad usage or an unreadable file. Diagnostics go to stderr and report the first error with a stable stage code (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`) and often a `help` line with the fix.
4. Finish only when the program exits successfully and its output matches the request. Checking alone does not verify runtime behavior.

Use `agentica help NAME --json` to inspect a builtin without a program file (unknown names exit 2). If `agentica` is not on `PATH`, use the path supplied by the user. Pass program arguments after the file; `System.args()` reads them. Process spawning requires `--allow-run`. `--max-steps N` bounds execution to N expression/statement entries across all tasks (`RUNTIME-STEP-LIMIT`; not an I/O timeout), and `--seed N` makes `Random` repeatable.

## When to read a reference

Read only the files the task needs:

| Read | When the program |
|---|---|
| [references/builtins.md](references/builtins.md) | calls a builtin whose signature is not shown below (`String`, `List`, `Map`, `Range`, `Int`, `Float`, `IO`, `System`, `Time`, `Random` functions), sorts, or reads counted input |
| [references/examples.md](references/examples.md) | needs a complete program to start from |
| [references/modules.md](references/modules.md) | spans several files, or imports `std/` or `pkg/` modules |
| [references/json.md](references/json.md) | reads or writes JSON |
| [references/files.md](references/files.md) | reads or writes files, directories, or paths |
| [references/processes.md](references/processes.md) | starts other programs (`Process`) |
| [references/tasks.md](references/tasks.md) | runs work concurrently (`Task`) |
| [references/network.md](references/network.md) | uses TCP, TLS, or HTTP (client or server) |
| [references/bdd.md](references/bdd.md) | writes `.feature` specifications or BDD step handlers (its report is `Json`: also read `json.md`) |
| [references/diagnostics.md](references/diagnostics.md) | hits a diagnostic code whose meaning or fix is unclear |

For fixed JSON records, prefer structs with typed fields. Use `Json`/`JSON.object` for genuinely dynamic data; maps and lists are homogeneous. For stdio protocols, write one message per line, flush stdout with `IO.flush()`, and send logs to stderr with `IO.warn()`.

## Style

Write the Ruby forms. Each has a longer module form that means the same thing.

| Write | Same as |
|---|---|
| `s.length`, `xs.size`, `s.strip.split(" ")` | `String.length(s)`, `List.size(xs)`, `String.split(String.trim(s), " ")` |
| `n.to_s`, `s.to_i!`, `n.to_f` | `String.from_int(n)`, `String.to_int!(s)`, `Float.from_int(n)` |
| `"total: #{n}"` | `"total: " + String.from_int(n)` |
| `!done && (a \|\| b)` | `not done and (a or b)` |
| `count += 1` | `count = count + 1` |
| `xs.map do \|x\| x * 2 end` | `List.map(xs, &double)` with a separate `def double` |
| `xs = xs.push(4)` | `xs = List.append(xs, 4)` |

Values never change in place: a method returns a new value, so assign it (`xs = xs.push(4)`).

## Program shape

- A file has top-level `def`, `struct`, `enum`, and `import` declarations. Functions, structs, and enums may use `export`. No executable statements at the top level.
- The root file needs exactly one `def main() -> Void` with no parameters. Running a program calls only that entrypoint.
- Blocks end with `end`. Indentation is for reading only.
- `#` starts a comment that runs to the end of the line.
- Function calls always use parentheses, even with no arguments: `main()`, `puts("hi")`. Only a method on a builtin value may drop them, when it has no arguments other than a trailing block (`s.length`, `xs.size`, `xs.each do |x| ... end`), and so may a module function with no arguments, builtin or through an import alias (`IO.gets!`, `IO.eof?`, `Util.reset`). `f = Util.helper` is a call; `&Util.helper` is the function value.
- A newline ends a statement. Inside `(...)`, `[...]`, and `{...}` an expression may span lines, and a trailing comma is allowed. To split a long expression, wrap it in parentheses.
- Reserved words: `def struct enum case do import export end if elsif else while for in return try true false nil and or not`.
- Extra blank or comment lines between statements are ignored.

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
| `Range` | `a..b` (includes `b`) or `a...b` (excludes it) over `Int`; prints as `1..5`; see `references/builtins.md` |
| `Option[T]` (example) | A user-defined generic enum; `Option` is not a builtin type |
| `Json` | opaque JSON value; use `JSON` functions to access it |
| `Fn[A, ..., R]` | function value (a block or `&name`); last type is the return, preceding types are parameters; `Fn[Void]` takes no arguments |
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

Leave a blank line after the `end` of every `def`, `struct` and `enum` before the next declaration (`PARSE-MISSING-BLANK-LINE`).

- Every parameter and the return type need an annotation.
- Structs, enums, and function declarations are top level only. Enum type parameters apply only to their payload types; generic functions and structs are not supported. There are no user methods, nested functions, default arguments, or overloading; closures are written as blocks (see "Blocks and closures").
- Functions can be called before they are declared, and can be recursive. Calls nest at most 10000 deep (`RUNTIME-STACK-OVERFLOW`); tail calls (`return f(...)`) do not count toward the depth limit, except in a program that uses `TCP`, `TLS`, `HTTP` or `BDD`, which runs on the evaluator.
- A function whose result is not `Void` must `return` on every path. A loop does not count as a return. The last expression is not returned implicitly.
- `return` alone and reaching the end complete a `Void` function. A `Nil` function explicitly returns `nil`.

## Statements

```ruby
count = 0              # new variable, type inferred (Int)
total: Float = 0.5     # new variable with an annotation
count += 1             # update: same name, same type

if count > 3
  puts("big")
elsif count > 1
  puts("medium")
else
  puts("small")
end

while count < 10
  count += 1
end

for item in items      # items is a List[T]; item is a new, read-only variable
  puts(item)
end

for i in 0...n         # 0 to n - 1; 1..n includes n
  puts(i)
end

3.times do |i|         # also a.upto(b) and a.downto(b) with a block
  puts(i)
end

case option
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
- `for` takes a `List[T]` or a `Range` (`a..b` includes `b`, `a...b` excludes it; both `Int`). A range iterates without building a list; an empty or reversed range runs zero times. There is no `range(n)`; write `0...n`, `n.times`, `a.upto(b)` or `a.downto(b)`.
- `case value` ... `end` is a statement, with arms `pattern -> block` (a `do` after the value is allowed but not needed). Each arm has a normal block and its bindings are local to that arm. A short arm may put one simple statement on the arrow line: `1 -> puts("one")`, `Command.Add(n) -> total += n`; more lines may follow it.
- Patterns are primitive literals, `_`, or qualified enum variants with one direct binding or `_` discard per payload position. Nested patterns and guards are not supported.
- Enum cases cover every variant or use `_`. Every non-enum case—including `Bool` and `Nil`—requires a top-level `_`. It must be the final arm; duplicate or unreachable arms are checker errors.
- `if` and `while` conditions must be `Bool`. There is no truthiness: `if 1` is an error.
- `break` leaves the innermost `while`/`for`; `next` skips to its next iteration. Each stands alone on its line (no `break if x`; write an `if`). They cannot cross a block or function: inside a block, `return` leaves the block (Ruby's `next`). Using them outside a loop is `CHECK-LOOP-CONTROL`.
- Assignment is a statement, not an expression. There is no `x[i] = v`, `x.f = v`, or `continue`.

## Expressions

- Literals: `42`, `3.14`, `"text"` (escapes `\" \\ \# \n \r \t`), `true`, `false`, `nil`. A minus sign is an operator, not part of the literal.
- Interpolation: `"total: #{n + 1} for #{name}"` is a `String`. Strings go in as is, `Json` as JSON text, and other data values in their `IO.inspect` form (`2.5`, `[1, 2]`, `Item(name: "a")`); this is the value's `to_s`. Keep the expression on one line; `\#{` is literal text. `case` patterns and `import` paths take plain strings only.
- Lists: `[1, 2, 3]`. Maps: `{"a": 1, "b": 2}` (a repeated key keeps the last value and its first-insertion position; `Map.put` replacement also keeps that position).
- An empty `[]` or `{}` needs a known type: an annotation, a parameter, a field, or the function result. A non-empty list needs elements of one type.
- Struct construction uses named fields, all of them exactly once, in any order: `User(name: "Ana", age: 25)`.
- Enum variants are qualified by their type. Construct payload variants positionally (`Option.Some("hi")`) and nullary variants with or without empty parentheses (`Option.None` or `Option.None()`). Generic arguments are inferred from payloads and expected types; every type parameter must be known. A nullary generic variant therefore needs expected type context.
- Field access `user.name`; index `items[0]` and `stock["apple"]`. Strings cannot be indexed. List indexing is O(n); prefer `for` for traversal.
- Function call `f(a, b)` with positional arguments. Method call on a builtin value `s.upcase`, `xs.map do |x| ... end`: see "Methods on builtin types". Builtin module call `String.upcase(s)` is the same as `s.upcase`.
- `&name` references a declared top-level function, without capturing locals. `f: Fn[Int, Int] = &double`; call it with `f.call(21)`. A block (`do |x| ... end`, below) is also a function value and captures locals. Function values can be stored in containers, fields, parameters, and returns. Signatures must match exactly. Bare function names remain invalid as values. No standalone lambdas, equality, or JSON encoding; inspect prints `<Fn>`.

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
| 9 | `..` `...` (ranges, no chaining) |

- `+ - * /` take two numbers of the same type. There is no implicit conversion between `Int` and `Float`. `+` also joins two `String` values.
- `/` on `Int` truncates toward zero. `%` takes two `Int` values. A zero divisor is a runtime error, also for `Float`.
- `< <= > >=` take two numbers of the same type.
- `==` and `!=` take two values of the same primitive type (`Int`, `Float`, `Bool`, `String`, `Nil`), or two ranges. Lists, maps, structs, Results, Json and Fn values cannot be compared.
- Comparisons do not chain: write `a < b and b < c`, not `a < b < c`.
- `&&`, `||`, `!` take `Bool`, and `&&` / `||` short-circuit. `and`, `or`, `not` are the same operators. `!` / `not` bind tightly: write `!(a >= b)`. A `!` right after a name is part of the name (`read!`).
- Arguments and operands are evaluated left to right.

## Methods on builtin types

`receiver.name(args)` calls a builtin function with the receiver as its first argument. The checker picks the module from the receiver's static type, so there is no dynamic dispatch:

| Receiver type | Module |
|---|---|
| `String` | `String` |
| `List[T]` | `List` |
| `Map[K, V]` | `Map` |
| `Float` | `Float` |
| `Result[T]` | `Result` |
| `Json` | `JSON` |
| `Range` | `Range` |
| `Int` | `Int` (`times`, `upto`, `downto`) and aliases |

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
| any data value | `to_s` | the text `"#{x}"` gives |
| any data value | `inspect` | the text `IO.inspect(x)` prints |

Unlike Ruby, `"abc".to_i` returns `Result[Int]` (an error here), not `0`; `to_i!` halts on bad text. An unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the list of that type's methods.

Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `Json`, and lists, maps, Results, structs and enums made of those. `x.to_s` is the text `"#{x}"` gives: a `String` as is, a `Json` as its JSON text, and anything else in its `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`, `Item(name: "a")`, `Shape.Box(1, 2)`). `puts(x)`, `print(x)` and `IO.warn(x)` take any value with `to_s` and write that text. Only a top-level `Json` becomes JSON text; inside a list or Result it shows as `<Json>`, so `puts(JSON.parse(s))` prints `ok(<Json>)`. Functions, tasks and resource handles (sockets, files, processes, HTTP values) have no `to_s`: printing or interpolating one is `CHECK-TYPE-MISMATCH`, and `.to_s` on one is `CHECK-UNKNOWN-METHOD`. A struct field named `to_s` is read as the field. Unlike Ruby, `nil.to_s` is `"nil"`, and `puts([1, 2])` writes `[1, 2]` on one line.

`x.inspect` returns the `IO.inspect` form as a `String`, for the same types as `to_s`. It differs from `to_s` only for strings, which keep their quotes (`"a".inspect` is `"a"` with the quote characters), and for `Json`, which gives `<Json>`. Use `IO.inspect(x)` to print that form and get `x` back. The debug form is for display: strings use the host's escapes, so it is not guaranteed to be valid Agentica source (`"a\#{b}".inspect` shows `#{` without the backslash).

Values are immutable, so a method never changes its receiver: `xs.push(2)` returns a new list. Calling a builtin without effects and ignoring a non-`Void` result is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Functions ending in `!` are exempt, since they can halt, and so are builtins that take a function (`xs.map(&save)`), since the function may have effects. A negative literal receiver needs parentheses: `(-5).to_s`, because `-5.to_s` is `-(5.to_s)`.

```ruby
words = line.strip.split(" ")
puts(words.join(","))
first = words[0].to_i!
xs = xs.push(first)
```

## Blocks and closures

A block is a function written at the call site as the last argument. Prefer blocks over `&name` for short callbacks.

```ruby
doubled = xs.map do |x|
  x * 2
end
evens = xs.filter do |x| x % 2 == 0 end
total = xs.reduce(0) do |sum, x| sum + x end
sorted = people.sort_by do |p| p.age end
xs.each do |x|
  puts("item #{x}")
end
found = xs.any? do |x| x > 10 end
result = run(5) do |n| n + 1 end
```

- Write `do |a, b| ... end` or `do ... end` after the `)` of a call, or after a method name without parentheses (`xs.each do`). User functions need parentheses: `run(5) do ... end`, `start() do ... end` (a function through an import alias may drop them: `Util.start do ... end`). The called function's last parameter must be a `Fn` (`CHECK-BLOCK-TARGET`). Never `do || ... end` and never `{ |x| ... }`.
- Parameter types come from the call; annotate when there is no context: `do |x: Int| ... end` (`CHECK-BLOCK-TYPE` otherwise).
- The last expression is the block's value. `return value` leaves only the block. A non-`Void` block must give a value on every path. `try` in a block needs the block to return `Result[...]` known from the call (not in `map`/`sort_by`); end it with `ok(...)`.
- `case`, `while`, and `for` headers may end with an optional `do` (`while !done do`, `for x in xs do`); that `do` is never a block. Wrap a call with a block in parentheses there: `case (xs.map do |x| x end) do`.
- Blocks capture values when created; later changes outside do not affect them. A block cannot assign to an outer variable (`CHECK-CAPTURED-ASSIGNMENT`): build the value with `map`/`reduce`, or use a `for` loop. Block parameters cannot reuse visible names.
- A block is a `Fn[...]` value: return it, store it, pass it to `Task.spawn` through a function parameter, or register a BDD step with `BDD.step("pattern") do |args| ... end`.
- `List.each` runs a block for each element; `List.any?` / `List.all?` stop at the first deciding element.

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
- `Result.Ok(x)` / `Result.Err(m)` and `ok(x)` / `error(m)` are the same, as values and as `case` patterns. `Result.Ok(_)` discards the payload and supports `Result[Void]` without binding a Void value.
- `try` evaluates its Result operand once: success produces the payload; an error returns from the current function. Only a function returning Result may use it, but operand and enclosing success types may differ. It binds like unary `not`; use parentheses for a larger operand. Expected output T supplies `Result[T]` to the operand; the function return type alone does not infer that payload. Success paths still need explicit returns.

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

## Diagnostics

Forms from other languages (`let x = 5`, `match x`, `when 1`, `if x then`, `elif`, `fn(x: Int)`, `lambda do`, `len(x)`, `Hash.new`, `break if x`, `loop do`, `puts(x) if ok`) are rejected with a `help` line that names the Agentica form.
