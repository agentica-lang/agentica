# Agentica: future grammar

Status: proposals only. This document is not normative; implemented language behavior is specified in [`grammar.md`](grammar.md).

Working rule: when a phase of the [`roadmap.md`](roadmap.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

## 2. Landed: enums and pattern matching

Generic enums and exhaustive Elixir-style `case` matching are implemented. Their normative syntax and semantics are now in sections 4–6 of [`grammar.md`](grammar.md), with the same self-contained rules in the programming reference. Further extensions remain proposals.

## 3. Extensions without a normative grammar

| Extension | Direction | Pending decisions |
|---|---|---|
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
- **Ranges, sets and queues:** planned in [section 12](#12-data-structures). Meanwhile use `while` with a counter, `Map[T, Bool]` and `std/queue`.
- **Input:** a helper for lines of integers; IO.gets/IO.gets!, Result, and try already handle line reads and EOF.
- **Structures:** tuples or pairs ([section 12.5](#125-later)). Nested lists and matrices are exercised by the traveling-salesman example.
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

Status: implemented (roadmap "Ruby-style ergonomics"); the specification moved to `grammar.md` and the programming skill. What is still open is listed in 11.4. The rule below still decides which new forms to accept.

Agentica is presented as "Ruby with types". The evaluation logs (`docs/eval-diagnostics.md`) show that most agent errors are Ruby and Python habits: `s.length`, `x.to_i`, `!a`, `a && b`, `x += 1`. This section accepts the Ruby forms that keep static checking and immutable values, so the model's habits become valid code. The module forms stay valid; the Ruby forms become the style taught in the programming skill.

**Which forms to accept.** Evaluation logs come from one model, so a form seen there is a candidate, not a decision. Accept a form only when one of these holds:

1. **It is real Ruby**, with the same meaning or a typed version of it. Examples: `!`/`&&`/`||`, `+=`, `"#{x}"`, `do |x| ... end`, `s.length`, `while cond do`, top-level `puts`/`print`/`gets`, `puts(x)` with any value, `x.to_s` and `x.inspect` on every data value, `break`/`next`. When the typed version differs from Ruby (`to_i` and `gets` return a `Result`), document the difference.
2. **It makes Agentica consistent with itself.** The same spelling works wherever the language already uses it. Examples: `Result.Ok(x)` as a value because it is already a pattern, `ok(v)` as a pattern because it is already a value, `Command.Show` without parentheses because the pattern has none, and a one-line case arm because one-line blocks exist.

Any other form gets a `help` that names the Agentica form, but is not accepted. This covers forms from Python, JavaScript, Rust and Elixir (`let`, `var`, `match`, `fn`, `elif`, `len`). It also covers Ruby forms that do not fit (`when`, `then`, statement modifiers such as `x if c`, `loop do`, `Hash.new`). Before relying on a newly accepted form, check it with a second model in an evaluation round.

### 11.1 Operators (implemented)

`!`, `&&`, `||` and compound assignment are in `grammar.md`.

### 11.2 Methods on builtin types (implemented)

Methods, the Ruby aliases and `CHECK-UNUSED-VALUE` are in `grammar.md`.

### 11.3 String interpolation (implemented)

Interpolation and the `\#` escape are in `grammar.md`.

### 11.4 Blocks and closures

Blocks, closures, `List.each`, `List.any?` and `List.all?` are in `grammar.md`.

Still open: standalone lambdas (`inc = lambda do |x: Int| x + 1 end`), methods on user types and `{ |x| }` blocks.

### 11.5 Hints for foreign habits

Implemented: the hints are listed in `grammar.md`, section 7.

## 12. Data structures

Today the language has `List[T]`, `Map[K, V]`, `Result[T]`, user structs and enums (a user `Option[T]` is a generic enum), and `std/queue`, a FIFO of Strings whose `push` copies the list. There are no user generic functions, so a generic structure cannot be written in Agentica: it must be a builtin, like `Map`. Each one lands in the evaluator and the VM in the same PR, with the grammar, the programming skill and the site docs.

Order: ranges first (12.1), then `Set[T]` (12.2), then `Queue[T]` (12.3). Faster lists are 12.4; the rest is later (12.5). `Range`, `Set` and `Queue` join the reserved type and module names: a user `struct Set`, `enum Range` or `import ... as Queue` becomes `CHECK-REDEFINED-NAME`.

### 12.1 Ranges

Agents write Ruby loops (`for i in 0...n`, `n.times do |i|`) and today must rewrite them as `while` loops with a counter. Ranges accept those forms.

```agentica
for i in 0...3 do
  puts(i)
end
# 0, 1, 2

for i in 1..3
  puts(i)
end
# 1, 2, 3

3.times do |i|
  puts(i)
end
# 0, 1, 2

1.upto(3) do |i|
  puts(i)
end
# 1, 2, 3

evens = (0..10).to_a.filter do |n|
  n % 2 == 0
end
```

- `a..b` includes `b`; `a...b` excludes it, as in Ruby. Both operands are `Int`; anything else is a type error, like other operators. The result has the builtin type `Range`.
- Precedence: lowest, below `or`/`||`, and not associative, so `0...n + 1` is `0...(n + 1)` and `1..2..3` is `PARSE-UNEXPECTED-TOKEN` at the second operator. `x = 0...n` and `f(0..n)` need no parentheses. A line that ends in `..` or `...` does not continue on the next line, like other binary operators. Calling a method needs parentheses: `(1..5).to_a`.
- `for x in range` yields each `Int` in order, without building a list. A range whose end is before its start is empty; there is no reverse iteration (use `List.reverse` on `to_a`). Each iteration costs steps like `for` over a list. Iteration up to the largest `Int` must not overflow.
- `Range` methods (and module functions `Range.name(r, ...)`):
  - `size -> Int`: the number of values; `RUNTIME-INTEGER-OVERFLOW` when it does not fit in `Int` (for example `(0..9223372036854775807).size`).
  - `to_a -> List[Int]`: capped at 1,048,576 values like `List.repeat`; above that, `RUNTIME-INVALID-COUNT`.
  - `include?(x: Int) -> Bool`, `each(Fn[Int, Void]) -> Void`.
  - `first -> Result[Int]` and `last -> Result[Int]`: the first and last included values, an error for an empty range. Unlike Ruby, `(1...5).last` is `ok(4)`, not `5`.
- `Int` methods for loops, all returning `Void`: `n.times(Fn[Int, Void])` calls the block with `0` to `n - 1` (nothing when `n <= 0`); `a.upto(b, Fn[Int, Void])` with `a` to `b` (nothing when `b < a`); `a.downto(b, Fn[Int, Void])` with `a` down to `b` (nothing when `b > a`).
- Text form: `1..5` and `1...5`, as Ruby's `inspect`. Ranges compare with `==` (same start, end and kind); they hold only `Int`s, so this needs no new equality rule.
- VM: a `Range` value is a small immutable object (start, end, kind). `for` over a literal lowers to a counter loop with no allocation; `for` over a `Range` variable reads its start and end once and runs the same counter loop, never `to_a` (so the `to_a` cap does not apply).
- Open: `step` (`(0..10).step(2)`), and ranges of `String` or `Float`. Not planned until a real program needs them.

### 12.2 Sets

```agentica
seen = Set.new(["a", "b"])
seen = seen.add("c")
puts(seen.include?("a"))   # true
puts(seen.size)            # 3
```

- `Set[T]` is a builtin generic, immutable like `Map`. Elements are `Int` or `String`, like `Map` keys. Iteration and `to_a` follow first-insertion order, like `Map.keys`.
- Functions (also methods, with the set first):

  | Function | Result |
  |---|---|
  | `Set.new(items: List[T]) -> Set[T]` | duplicates dropped, first one kept; `Set.new([])` needs an expected type, like an empty list. One arity, so the builtins catalog needs no overloads. |
  | `Set.add(s: Set[T], x: T) -> Set[T]`, `Set.delete(s: Set[T], x: T) -> Set[T]` | a new set; the input is unchanged |
  | `Set.include?(s: Set[T], x: T) -> Bool`, `Set.size(s) -> Int`, `Set.empty?(s) -> Bool` | |
  | `Set.to_a(s: Set[T]) -> List[T]` | first-insertion order |
  | `Set.union(a, b)`, `Set.intersection(a, b)`, `Set.difference(a, b) -> Set[T]` | order: `a` first, then new elements of `b` |
  | `Set.subset?(a: Set[T], b: Set[T]) -> Bool` | every element of `a` is in `b` |

- `for x in set` iterates in order.
- Text form: `Set[1, 2]`. No `==` at first, like `List` and `Map` (`grammar.md` §6 allows `==` on primitive values only). Sets are not JSON-encodable at first.
- VM: built on the HAMT of 7e PR 5d, so it comes after maps.

### 12.3 Queues

- `Queue[T]` is a builtin generic, persistent FIFO (two lists): `Queue.new(items: List[T]) -> Queue[T]` (front first; `Queue.new([])` needs an expected type), `Queue.push(q, x: T) -> Queue[T]` (at the back), `Queue.peek(q) -> Result[T]` (the front), `Queue.drop(q) -> Queue[T]` (without the front; an empty queue stays empty), `Queue.size(q) -> Int`, `Queue.empty?(q) -> Bool`, `Queue.to_a(q) -> List[T]` (front to back). Also as methods. Used linearly, each operation is O(1) amortized; reusing an old version can cost O(n) once.
- `for x in queue` iterates front to back. Text form: `Queue[1, 2]`, front first. No `==`, like `List`. Not JSON-encodable at first.
- `pop` returning both the value and the rest waits for tuples (12.5). Until then, `peek` then `drop`.
- `std/queue` stays, deprecated: `Queue` becomes a reserved name, so `import "std/queue.agc" as Queue` would fail with `CHECK-REDEFINED-NAME`. 8c renames the documented alias to `StringQueue` in `README.md`, `examples/queue.agc`, `docs/grammar.md`, the programming skill's modules reference, `tests/modules-test.rkt` and `tests/stdlib-distribution-test.rkt`, keeps `stdlib/queue.agc` and its entry in `src/stdlib.rkt` (the only embedded module, so the `std/` path and its tests keep their coverage), keeps the `examples/queue.agc` smoke runs in `.github/workflows/ci.yml` and `release.yml` working, and notes the break in the changelog. `std/queue` is removed once another `std/` module exists.

### 12.4 Faster lists

Not a new type: `List` keeps its API and meaning, and only its representation changes. Today `List.append` copies the list (O(n)), and indexing is O(n) in the evaluator. A persistent vector (a 32-way trie with a tail buffer, as in Clojure and Scala) makes `append`, `set` and indexing O(log32 n), near constant, and keeps old versions unchanged. Both backends change in the same PR; output, step counts and diagnostics stay the same. Measure with `benchmarks/` before and after.

### 12.5 Later

Each needs a real program first.

- **Tuples:** `(Int, String)` values and destructuring, to return two values without a struct; then `Queue.pop`.
- **`Bytes`:** binary data instead of `List[Int]` (`IO.read_bytes`, `String.from_bytes`).
- **Priority queue (`Heap[T]`):** for Dijkstra and scheduling; elements `Int`, `Float` or `String`, or a key function.
- **Sorted map or set:** iterate in key order; today sort the keys.
- **Deque:** both ends of a `Queue`.
