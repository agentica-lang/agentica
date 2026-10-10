# Agentica: future grammar

Status: proposals only. This document is not normative; implemented language behavior is specified in [`grammar.md`](grammar.md).

Working rule: when a phase of the [`roadmap.md`](roadmap.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

## 2. Landed: enums and pattern matching

Generic enums and exhaustive Elixir-style `case` matching are implemented. Their normative syntax and semantics are now in sections 4–6 of [`grammar.md`](grammar.md), with the same self-contained rules in the programming reference. Further extensions remain proposals.

## 3. Extensions without a normative grammar

| Extension | Direction | Pending decisions |
|---|---|---|
| Interpolation | Specified in [section 11](#11-ruby-style-ergonomics) | — |
| Function generics | Reuse functions with different types | Syntax, inference, and constraints |
| Closures and methods | Blocks and methods on builtin types are specified in [section 11](#11-ruby-style-ergonomics); user methods remain open ([module attachment](#7-possible-metatables-ruby-style-modules)) | Standalone lambdas; methods on user types |
| Modules | Group behavior and split programs into files | Import, visibility, cycles, and module attachment (section 7) |
| C FFI | Safe wrappers over native calls | Pointers, ownership, ABI, and calls from the interpreter |
| Async and fibers | Suspend execution on I/O; initially one thread. See [section 8](#8-concurrency-and-parallelism) | API, cancellation, and error propagation |
| Actors | Own messages and mailboxes | Syntax, isolation, shared values, and supervision |

## 4. Standard library and function values (phases 5f2–5m)

Fixed here so each roadmap phase can take it as its specification. Named function values (5j) now ship in the core; their normative grammar is in `grammar.md`. Typed JSON, builders/schema, and file imports also ship in the core; remaining extensions stay planned.

```ebnf
postfix_expr     = primary, { ".", NAME
                            | ".", "call", "(", [ arguments ], ")"
                            | "[", expression, "]" } ;

primary          = (* …core forms, plus: *)
                 | "&", NAME
                 | TYPE_NAME ; (* core JSON.decode/schema type arguments *)
```

- **`&name` and `.call(...)`:** `&name` turns a top-level function into a value of type `Fn[...]`, and `value.call(args)` calls it. `call` is not a reserved word: it has this meaning only right after a `.` and before `(`. There are no closures: `&name` does not capture variables. The checker requires `name` to be a declared function and compares parameters and return type with the expected type. Precedence 1, like the named call.
- **Bare type names:** core JSON.decode/schema arguments include imported types such as Models.User. Types are not runtime values.
- Function values, `Void`, `Process`, and TCP/TLS/HTTP handles and records are core; their normative APIs live in grammar.md. Opaque handles have no constructor or fields; inspect prints a type marker.
- `Void`, `Process`, `Fn`, `BDD`, `Json`, `JSON`, `Task`, `TCP`, `TLS`, `HTTP` and networking types are reserved in the core; typed decoding and schema functions are core.

```ruby
def double(n: Int) -> Int
  return n * 2
end

def main() -> Void
  f: Fn[Int, Int] = &double
  puts(String.from_int(f.call(21)))
  if String.contains?("agentica", "gent")
    puts("found")
  end
end
```

Programs that phase must reject:

```ruby
x = User               # A type is valid only as an argument of JSON.decode or JSON.schema.
f = &missing           # &name requires a declared function.
ready = done?          # A function name is not a value; use &done?.
```

Typed JSON decoding, builders/schema, and file imports/exports now ship in the
core; their normative contracts live in grammar.md and the programming reference.

## 5. Remaining `List` operations

The collection module is `List`, keeping `List.size`; the earlier `Enum` proposal is superseded. Phase 5n already implements `List.append`, `List.set`, `List.repeat`, `List.reverse`, `List.concat/take/drop/at`, `List.map/filter/reduce`, `List.sort/sort_by`, and `Map.values/get/delete`. Their current contracts live in `grammar.md` and the programming reference. Knight-tour and small traveling-salesman examples exercise construction, persistent updates, and nested lists. Operations below remain planned, not part of the implemented core.

Remaining callback operations depend on function values (section 4, phase 5j): `List.any?` and `List.all?`. Without closures, a function cannot capture variables; extra state travels through parameters or the accumulator.

```text
List.sum(list: List[Int]) -> Int
List.member?(list: List[T], item: T) -> Bool
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool
```

Planned rules:

- Generic builtins, no user generics. Collection operations preserve their inputs.
- `List.member?` requires primitive equality.
- Callbacks require exact parameter and return types.
- `List.size` remains the count operation; no duplicate `count` alias is planned.
- Linked-list operations remain linear; repeated append costs O(n²). A persistent vector is a later optimization.

Future example, after function values and the remaining operations land:

```ruby
def double(n: Int) -> Int
  return n * 2
end

def add(total: Int, n: Int) -> Int
  return total + n
end

def main() -> Void
  numbers = [3, 1, 2]
  sorted = List.sort(numbers)
  doubled = List.map(sorted, &double)
  puts(String.from_int(List.reduce(doubled, 0, &add)))
end
```

Continue primitive operations through the builtins catalog. Function values (5j) are now available, but collection callbacks remain pending; keep checker, evaluator, grammar, and programming reference in sync when adding them.

### Other gaps for code-challenge programs

Besides remaining List operations, these gaps remain. Check each against a real task before building it.

- **Math:** `abs`, `min`, `max`, `pow`, `sqrt`, `floor`, `ceil`, `gcd`.
- **Maps and sets:** a set type; meanwhile use `Map[Int, Bool]` or `Map[String, Bool]`. Dedicated stack, queue, and priority queue APIs remain future work.
- **Input:** a helper for lines of integers; IO.gets/IO.gets!, Result, and try already handle line reads and EOF.
- **Structures:** tuples or pairs. Nested lists and matrices are exercised by the traveling-salesman example.
- **Performance:** `List.append` copies the list, so repeated appends are O(n²); a persistent vector remains a possible later optimization. Maps already use Racket immutable hashes with structural sharing ("Faster maps" in the roadmap).
- **Bounds:** Int is signed 64-bit and recursion has a 10000-call limit. Large challenge workloads still need practical runtime measurements.
- **Outside the language:** online judges do not accept Agentica, so challenges run locally against hidden cases, as in `tests/eval/`. The interpreter is a tree walker on Racket, so judge time limits are tight.

## 6. Native runtime

The native runtime is now planned as a bytecode VM written in C11 with the Boehm GC (roadmap Phase 7), instead of the earlier procedural C++20 idea. libevent remains an option for the task and I/O event loop; Phase 7b decides. These choices are not part of the grammar and must not appear in Agentica programs.

Integrating the native host with a C library does not by itself solve the FFI of Agentica: an interpreter needs native wrappers or a call layer that respects the ABI. Including libevent does not automatically provide fibers or actors either.

For now we do not introduce interfaces, traits, inheritance, JIT, distribution, or parallelism. The semantics of the language must be preserved when the AST evaluator is replaced by a future VM.

## 7. Possible metatables: Ruby-style modules

Exploratory only: no implementation or phase is assigned. Group shared behavior visually, then attach it to maps, lists, or records. Prefer Ruby's `module ... end`, `def ... end`, `self`, and `.extend(...)` over new spellings such as `defmod` or Elixir's `defmodule`. Borrow Elixir's immutable-value approach and keep static checking; adopting this syntax does not require classes or inheritance.

Possible shape, deliberately Ruby-parsable rather than current Agentica syntax:

```ruby
module User
  # Proposed receiver: Map[String, String]; result: String.
  # These comments illustrate types, not a settled annotation syntax.
  def name()
    return self["name"]
  end

  def greet()
    return "Hello " + self.name()
  end
end

def main()
  ana = {"name" => "Ana"}.extend(User)
  bob = {"name" => "Bob"}.extend(User)
  puts(ana.greet()) # Hello Ana
  puts(bob.greet()) # Hello Bob
end
```

The same idea could give a list named methods without changing its normal indexing:

```ruby
module Numbers
  # Proposed receiver: List[Int]; result: Int.
  def first()
    return self[0]
  end
end

numbers = [10, 20, 30].extend(Numbers) # Fragment inside main.
puts(String.from_int(numbers.first())) # 10
puts(String.from_int(numbers[1]))      # 20
```

Candidate semantics and boundaries:

- A module holds shared methods, not per-object state. A method's `self` is the attached receiver; methods can call sibling methods through `self`.
- Unlike Ruby's mutating `extend`, the candidate Agentica form returns a new immutable wrapper. The original value is unchanged. Module selection and method signatures must be known to the checker; incompatible receivers and unknown methods are check errors.
- Normal map/list indexing, insertion order, and missing-key/index diagnostics stay unchanged initially. Attachment adds behavior; it does not make collection lookup faster or combine List and Map into a mixed PHP-style array.
- Lua-style fallback lookup (`__index`), custom indexing, operators, or callable objects could be a later layer. Decide which typed hooks are useful before adding them; do not make every lookup run arbitrary callbacks by default.

Open decisions before implementation:

- How receiver, argument, and result types are declared while keeping Ruby-parsable syntax: signature comments or a separate RBS-style file are possibilities, not decisions.
- The static type of an attached value, visibility, method collisions, multiple modules, and whether collection operations preserve attached behavior.
- Whether `.extend(Module)` is sufficient or an explicit `Meta.attach(value, Module)` API is also needed. Prefer one spelling, not both without a real need.
- Name resolution for bare module arguments and how module namespaces relate to records and future imports.

**Ruby tooling goal, not a compatibility promise:** existing Agentica `->` signatures and `struct` declarations are not Ruby syntax. The examples use `=>` for String-keyed maps; Ruby's `{"name": value}` creates a Symbol key, unlike Agentica's current map literal. Reusing Ruby linters such as RuboCop requires a Ruby-parsable source subset or a translation step, plus configuration for Agentica conventions. Verify that with real tooling before claiming support. None of these spellings or type alternatives changes the core grammar today.

## 8. Concurrency and parallelism

Lightweight I/O tasks are implemented before networking in phase 5j2. Their normative API lives in grammar.md: Task.spawn takes Fn[A, R] and one argument and returns Task[R]; Task.await returns R; Task.sleep takes nonnegative milliseconds. Channels and CPU parallelism remain proposals. Supporting multiple connections is the concrete reason to prepare evaluator isolation before TCP and HTTP.

### Racket building blocks

| Tool | Module | Parallel? | Notes |
|---|---|---|---|
| Green threads, channels, `sync`, semaphores | `racket/base` | One core | Cheapest; enough for I/O concurrency; no new dependency |
| Parallel threads, `thread #:pool` | `racket/base` | Multicore on supported CS builds | Available since 8.18.0.2; synchronization costs need measurement |
| Places, `place-channel` | `racket/place` | Real multicore | One VM per place; messages serialized; heavy |
| Futures | `racket/future` | Limited | Parallel only for a safe value subset; finicky performance; not proposed |

The implementation uses ordinary coroutine threads. Racket CS 9.3 also supports parallel thread pools; places are not the only multicore option. See [Racket threads](https://docs.racket-lang.org/reference/threads.html). Add CPU parallelism only after measuring a concrete workload and reviewing shared state.

### Shape: builtin modules, no grammar change

Task is a builtin module over Racket primitives using function values (5j) and a generic opaque result type, with no new keywords. The remaining channel proposal is:

```text
Channel.new() -> Channel[T]
Channel.send(c: Channel[T], v: T) -> Void
Channel.recv(c: Channel[T]) -> T
```

- Named functions have no closures. Task inputs travel through one argument and results through Task.await; future channels could provide repeated exchanges.
- Channel[T] would be a builtin opaque generic. Buffering, close, timeout and cancellation rules must be decided together.
- Immutable values can be shared safely, but ports, future sockets and contextual services are resources with state. They still need ownership or synchronization rules.
- Task diagnostics already terminate the whole evaluation, even when unawaited; Result.error remains a normal result.

### Future process polling

Process spawning may later expose a non-blocking helper:

```text
Process.poll_line(p: Process, timeout: Int) -> Result[String]
```

A loop can alternate between requests and polling with sync/timeout on child output. This is not part of the task phase.

### Implemented evaluator isolation

The evaluator prepares immutable function/struct tables once per evaluation, then creates independent scopes, depth, returns and diagnostic escapes for each task. src/task.rkt owns supervision, cached results and the synchronized global step budget. A run custodian cancels pending tasks and closes new resources at completion or interruption; borrowed ports remain open. BDD rejects pending tasks on handler return and keeps scenario continuation.

### Open decisions

- Whether a concrete application needs channels or Process.poll_line.
- Whether measured CPU workloads justify parallel thread pools or places; default no.
- Whether to expose task timeouts or explicit cancellation. Current await has no timeout; returning from the entrypoint cancels pending work.

## 9. Files and paths (implemented)

The filesystem phase is implemented; its normative signatures and behavior now
live in [`grammar.md`](grammar.md#files-and-paths). It adds `File`, `Dir` and
`Path`, an opaque evaluation-owned `FileHandle`, and the `FileInfo` record.
Host filesystem permissions apply without a separate capability flag. Reads
and writes are limited to regular files and symlinks to regular files. Whole
text helpers and each stream operation cap data at 1 MiB and use strict UTF-8.
Timed stream operations serialize per handle and close the handle only when
active I/O times out. `Dir.mkdir` is recursive and idempotent; path resolution
is lexical and does not resolve symlinks.

## 10. Void and processes (implemented)

Strict `Void` and the `Process` module are core. Their normative signatures,
completion/type restrictions, stream limits, deadlines, and cleanup rules live
in `grammar.md`. `Nil` remains data; successful fallible completion uses
`Result[Void]` and `ok()`. Native FFI can map a foreign void return to the same
completion concept when its ABI and ownership design lands.

Process spawning requires `--allow-run`, off by default. Operations use literal
arguments, inherited environment/working directory, and per-call 1 MiB stream
limits. Direct children are killed and reaped when evaluation ends. Process
polling and arbitrary descendant-tree supervision remain future designs.

## 11. Ruby-style ergonomics

Status: specified, planned next (roadmap "Ruby-style ergonomics"). Each part moves to `grammar.md` and the programming reference when its pull request lands.

Agentica is presented as "Ruby with types". The evaluation logs (`docs/eval-diagnostics.md`) show that most agent errors are Ruby and Python habits: `s.length`, `x.to_i`, `!a`, `a && b`, `x += 1`. This section accepts the Ruby forms that keep static checking and immutable values, so the model's habits become valid code. The module forms stay valid; the Ruby forms become the style taught in the programming skill.

### 11.1 Operators

- `!e` is `not e`; `a && b` is `a and b`; `a || b` is `a or b`. Same types, same precedence, same short-circuit rules.
- A `!` that directly follows a name is still part of the name (`read!`, `to_int!(`), and `!=` is still inequality. `!` starts an expression only where an operand is expected.
- `x += e`, `x -= e`, `x *= e`, `x /= e`, `x %= e` mean `x = x op e`. The target is a plain name that is already visible and assignable; the checker reports the same diagnostics as the long form.

```ruby
count = 0
if !done && (count < 3 || retry?)
  count += 1
end
```

### 11.2 Methods on builtin types

`receiver.name(args)` calls a builtin function of the receiver's module with the receiver as the first argument. The checker chooses the module from the receiver's static type:

| Receiver type | Module |
|---|---|
| `String` | `String` |
| `List[T]` | `List` |
| `Map[K, V]` | `Map` |
| `Float` | `Float` |
| `Result[T]` | `Result` |
| `Json` | `JSON` |
| `Int` | aliases only (below) |

- `receiver.name` without parentheses on a non-struct receiver is a method call with no arguments: `s.length`, `xs.size`, `r.ok?`.
- On a struct, `.name` is still field access. Structs and enums have no methods; user functions cannot be called as methods.
- `.call(...)` still invokes a `Fn` value.
- Unknown methods are `CHECK-UNKNOWN-METHOD`, with a suggestion from the methods of that type.
- Methods are resolved before running; there is no dynamic dispatch.

Ruby aliases, all resolved to existing functions:

| Receiver | Alias | Same as |
|---|---|---|
| `String` | `size` | `String.length` |
| `String` | `to_i`, `to_i!` | `String.to_int` (Result), `String.to_int!` |
| `String` | `to_f`, `to_f!` | `String.to_float` (Result), `String.to_float!` |
| `String` | `strip` | `String.trim` |
| `String` | `include?`, `start_with?`, `end_with?` | `contains?`, `starts_with?`, `ends_with?` |
| `String` | `to_s` | the same string |
| `List` | `length` | `List.size` |
| `List` | `push` | `List.append` |
| `List[String]` | `join` | `String.join` |
| `Int` | `to_s`, `to_f` | `String.from_int`, `Float.from_int` |
| `Float` | `to_s` | `String.from_float` |
| `Float` | `to_i`, `to_i!` | `Float.to_int` (Result), `Float.to_int!` |

Unlike Ruby, `"abc".to_i` does not return `0`: it returns `Result[Int]`, as `String.to_int` does. Use `to_i!` to halt on bad text, or `try`.

Values are immutable, so methods never change their receiver. `xs.push(2)` returns a new list. A call to a builtin without effects whose result is not used is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`.

```ruby
words = line.strip.split(" ")
puts(words.join(","))
first = words[0].to_i!
```

### 11.3 String interpolation

- `"text #{expression} text"` builds a `String`. A `String` value is inserted as is; any other data value uses its `IO.inspect` form (`7`, `2.5`, `true`, `nil`, `[1, 2]`, `Item(name: "a")`). A Void call is a check error.
- `\#` writes a literal `#`. A string without `#{` is unchanged.
- The expression must stay on the same line and cannot contain comments. Strings may appear inside it: `"#{names.join(", ")}"`.
- Before this change, `#{` inside a string was plain text. Strings that need it literally must use `\#{`.

### 11.4 Blocks and closures

A block is a function written at the call site, as the last argument:

```ruby
doubled = xs.map do |x|
  x * 2
end
evens = xs.filter do |x| x % 2 == 0 end
total = xs.reduce(0) do |sum, x|
  sum + x
end
xs.each do |x|
  puts("item #{x}")
end
```

- **Syntax.** `do |p1, p2| ... end` or `do ... end` (no parameters) right after the closing `)` of a call or method call, or after a method name without parentheses (`xs.each do ... end`). Only `do`, not `{ |x| }`, because `{` is the map literal. The block body may start on the same line: `do |x| x * 2 end`.
- **Where.** The block is the last argument. It is allowed only when the called function's last parameter is a `Fn` (`CHECK-BLOCK-TARGET` otherwise). This covers user functions with a final `Fn` parameter, `List.map/filter/reduce/sort_by/each/any?/all?` and `BDD.step`.
- **Parameter types.** Known from the context: the parameter types of a user function's `Fn`, or the builtin's rule (`xs.map` gives `x` the element type). Parameters may be annotated: `do |x: Int| ... end`. With neither, `CHECK-BLOCK-TYPE`.
- **Result.** The block's body is a list of statements. `return value` returns from the block, not from the enclosing function, like a lambda; `try` also returns from the block. Without `return`, the value of the last expression statement is the block's value. A block whose result is not `Void` must produce a value on every path, like a function (`CHECK-MISSING-RETURN`).
- **Capture by value.** A block can read every variable visible where it is written. It captures their values when the block is created; later assignments outside do not change it. Assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`: use `reduce`, or a `for` loop. Block parameters and new variables inside a block cannot reuse a visible name (`CHECK-SHADOWED-NAME`).
- **Values.** A block has the type `Fn[A, ..., R]` and works everywhere a function value works: stored, returned, passed to `Task.spawn` or HTTP callbacks through a variable. Function values have no equality and no JSON form; `IO.inspect` prints `<Fn>`.
- **New builtins** for blocks: `List.each(list: List[A], f: Fn[A, Void]) -> Void`, `List.any?(list: List[A], f: Fn[A, Bool]) -> Bool`, `List.all?(list: List[A], f: Fn[A, Bool]) -> Bool`. Each callback runs in order; `any?` and `all?` stop at the first decisive element.

Standalone lambdas (`inc = lambda do |x: Int| x + 1 end`), methods on user types and `{ |x| }` blocks are out of scope for now.

### 11.5 Hints for foreign habits

Names from other languages get a grounded `help` that names the Agentica form:

| Written | Help |
|---|---|
| `len(x)` | `x.size` for lists and maps, `s.length` for strings |
| `str(x)`, `x.to_string()` | `x.to_s` |
| `print(x)` | `puts(x)` or `IO.print(x)` |
| `input()`, `read_line()`, `gets` | `IO.gets()` |
| `range(n)` | a `while` loop, or `for` over a list |
| `Int.to_float(n)`, `float(n)`, `int(x)` | `n.to_f`, `x.to_i` |
| `None`, `null` | `nil` |
| `elif`, `elseif`, `else if` | `elsif` |
| `x.to_i` used as an `Int` | `to_i` returns `Result[Int]`; use `x.to_i!` or `try x.to_i` |
