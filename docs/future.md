# Agentica: future grammar

Status: proposals only. This document is not normative; implemented language behavior is specified in [`grammar.md`](grammar.md).

Working rule: when a phase of the [`roadmap.md`](roadmap.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

Section 14 records ideas that were decided or rejected, so they are not proposed again.

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
- **Performance:** `List.append` copies the list, so repeated appends are O(n²); a persistent vector is planned in [section 12.4](#124-faster-lists). Maps already use Racket immutable hashes with structural sharing ("Faster maps" in the roadmap).
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
  - `to_a -> List[Int]`: capped at 1,048,576 values like `List.repeat`; above that, `RUNTIME-INVALID-COUNT`. Both this error and the `size` overflow point at the receiver.
  - `include?(x: Int) -> Bool`, `each(Fn[Int, Void]) -> Void`.
  - `first -> Result[Int]` and `last -> Result[Int]`: the first and last included values, an error for an empty range. Unlike Ruby, `(1...5).last` is `ok(4)`, not `5`.
- `Int` methods for loops, all returning `Void`: `n.times(Fn[Int, Void])` calls the block with `0` to `n - 1` (nothing when `n <= 0`); `a.upto(b, Fn[Int, Void])` with `a` to `b` (nothing when `b < a`); `a.downto(b, Fn[Int, Void])` with `a` down to `b` (nothing when `b > a`).
- Text form: `1..5` and `1...5`, as Ruby's `inspect`. 8a extends the `==` rule of `grammar.md` §6 to `Range`: two ranges are equal when start, end and kind match. The VM compares those fields, never object identity. `IO.inspect` shows the same form. Ranges are not JSON-encodable.
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

- `Queue[T]` is a builtin generic, persistent FIFO (two lists): `Queue.new(items: List[T]) -> Queue[T]` (front first; `Queue.new([])` needs an expected type), `Queue.push(q, x: T) -> Queue[T]` (at the back), `Queue.peek(q) -> Result[T]` (the front), `Queue.drop(q) -> Queue[T]` (without the front; an empty queue stays empty, like `List.drop` with a large count; check `peek` or `empty?` first when emptiness is an error), `Queue.size(q) -> Int`, `Queue.empty?(q) -> Bool`, `Queue.to_a(q) -> List[T]` (front to back). Also as methods. Used linearly, each operation is O(1) amortized; reusing an old version can cost O(n) once.
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

## 13. Shared tables (ATS)

ATS (Agentica Table Storage) plays the role of Erlang's ETS. Values are immutable, so passing one to a task shares it without a copy. What is missing is shared mutable state: a counter, or a cache that fills while tasks run. Today a task can only hand back a new value through `Task.await`. A table is one mutable place that tasks share through a handle.

A `Channel[T]` (§8) passes messages between tasks; a table is state that many tasks read and update. Each one waits for a program that needs it. `Table` becomes a reserved type and module name, a breaking change: a user `struct Table`, `enum Table` or `import ... as Table` becomes `CHECK-REDEFINED-NAME`, as §12 says for `Range`, `Set` and `Queue`.

```agentica
def count_visit(hits: Table[String, Int]) -> Void
  hits.add("home", 1)
end

def main() -> Void
  hits: Table[String, Int] = Table.new()
  a = Task.spawn(&count_visit, hits)
  b = Task.spawn(&count_visit, hits)
  Task.await(a)
  Task.await(b)
  IO.inspect(hits.get("home"))   # ok(2)
end
```

- `Table[K, V]` is a builtin opaque generic, like `Task[T]`. A table value is a handle: assigning or passing it shares the same table, it does not copy it. This is the one place where data values are shared and mutable, so the name and the type say so.
- **Nesting:** a `Table` may be a struct field, a list element, a `Map` value, or a `Task.spawn` argument or result. It may not be stored inside a table (next rule).
- **Keys and values:** keys are `Int` or `String`; any other key type is `CHECK-MAP-KEY-TYPE`, as for `Map` keys. `V` may not be `Void` or `Nil`, and `printable-type?` (`src/checker.rkt`) must hold for `V`. That walk is deep: it looks through struct fields, list elements, enum payloads, `Map` values and `Result`, and it rejects `Fn`, `Task`, every opaque handle (such as `FileHandle`, `Process` or `Socket`) and any new type such as `Table`. `Fn` is out because a block can capture a handle, which would get past this rule and could build cycles. A nested `Result[Void]` is allowed, because `printable-type?` accepts it. The walk checks each declaration once by name, so recursive generic enums cannot loop. The checker enforces this wherever a `Table[K, V]` type is written or inferred, with `CHECK-TABLE-VALUE` (span on the type, or on `Table.new()` when inferred).
- **Sharing values:** values are immutable, so storing one shares it safely. Each call is atomic, so a reader sees either the old value or the new one.
- Functions (also methods, with the table first):

  | Function | Result |
  |---|---|
  | `Table.new() -> Table[K, V]` | needs an expected type, like an empty `Map` |
  | `Table.put(t, k: K, v: V) -> Void` | insert or replace |
  | `Table.put_new(t, k: K, v: V) -> Bool` | insert only when the key is absent; `false` leaves the table unchanged (ETS `insert_new`) |
  | `Table.get(t, k: K) -> Result[V]`, `Table.has_key?(t, k: K) -> Bool` | |
  | `Table.delete(t, k: K) -> Void` | absent keys are ignored |
  | `Table.add(t, k: K, n: Int) -> Int` | `Table[K, Int]` only: adds `n` (absent counts as 0) and returns the new value, atomically (ETS `update_counter`); overflow halts with `RUNTIME-INTEGER-OVERFLOW` and leaves the table unchanged; on a table whose values are not `Int`, `CHECK-TYPE-MISMATCH` |
  | `Table.size(t) -> Int` | a snapshot read, O(1) |
  | `Table.keys(t) -> List[K]`, `Table.to_map(t) -> Map[K, V]` | snapshots, in first-insertion order; a key deleted and then put again goes to the end, as in `Map` |

- **Left out on purpose:** `get` with a default and `values`, which `Map` has. Use `Result.unwrap_or` and `to_map`.
- **Costs:** `get`, `put`, `put_new`, `has_key?`, `delete` and `add` take at most O(log n) in the table size (unlike `Map.delete`, which is O(n)). `size` is O(1). Taking a snapshot for `keys` or `to_map` is O(1) and blocks no other task; building its list or map is O(n).
- **Atomicity:** each call is atomic on its own. There are no transactions over several keys and no user code runs inside a call (no `update` with a block), so a call cannot deadlock or re-enter the table.
- **Read-modify-write:** `Table.add` is the only atomic update. `put_new` only inserts when the key is absent. To update any other existing value safely, let a single owner task do the writes. A compare-and-swap (`Table.replace`) waits for a real program.
- **Lifetime:** a table belongs to the execution that created it, like a `Task` handle. Inside that execution all its tasks share it, and the garbage collector frees it when no value refers to it. Using it from another execution (another BDD step, or a nested evaluation) halts with `RUNTIME-TABLE-CONTEXT`, so scenarios stay isolated (`docs/bdd.md`: scenarios run "with fresh JSON state and a fresh process"). There is no owner process and no named global table, unlike ETS: a task reaches a table only through a handle it was given.
  - **BDD:** handler registration is one execution, and each step of a scenario runs as its own execution (`src/bdd-runner.rkt` evaluates every step handler separately). A table created during registration and captured by a step block halts with `RUNTIME-TABLE-CONTEXT` when a step uses it. A step that needs a table creates its own and uses it only inside that step; it stores the table in nothing that outlives the step. To pass data to a later step, use the scenario's JSON state.
- **No `==`, no JSON, no `to_s`.** As for `Task`, `puts`, `print` and interpolation of a table give `CHECK-TYPE-MISMATCH`, and `.to_s` gives `CHECK-UNKNOWN-METHOD`. The rules are deep: `==` takes primitive values only, so a struct or list holding a table cannot be compared anyway; JSON encoding rejects a value with a table inside, as it does for `Task`; `IO.inspect` prints `<Table>` in place of the table, without its contents. Use `to_map` to see them.
- **Not in the first version:** ordered tables (`ordered_set`), duplicate keys (`bag`), match specifications, and tables shared between OS processes. Each waits for a real program.
- **Effects:** `Table.put`, `put_new`, `delete` and `add` carry the existing `concurrency` effect label, like `Task.spawn`. The label matters for `put_new` and `add`: their results may be ignored, so it keeps `CHECK-UNUSED-VALUE` away. `put` and `delete` return `Void`; they carry it so `help --json` shows the effect.
- **Backends:** the contract is only that each call is atomic. The evaluator and the VM land in the same PR.
  - Evaluator: each table is a box holding an immutable persistent structure. A write computes the new structure outside any lock and installs it with `box-cas!`, retrying if another task won; no user code runs in a call, so the retry is safe. Tasks are Racket threads that may be killed (`custodian-shutdown-all`), and a task killed mid-call leaves the box at either the old or the new version. Snapshots (`keys`, `to_map`, `size`) read the box once, so taking one is O(1) and never blocks other tasks. `Table.add` computes the sum first: on overflow it halts with `RUNTIME-INTEGER-OVERFLOW` and installs nothing.
  - VM: one OS thread runs the scheduler (`docs/vm.md` §10.2), and a table call does not yield, so it is atomic.
  - Layout: O(log n) `delete` with insertion order needs its own layout, not the `Map` layout. 9a builds a persistent ordered map for it in both backends, for example a balanced tree: a persistent hash from key to (sequence, value), plus a persistent sorted map from sequence to key.

## 14. Decided: no shadowing

**Rule:** a name visible in an outer scope cannot be declared again in an inner scope, and block parameters cannot reuse a visible name (`CHECK-SHADOWED-NAME`). This stays.

**Why:**

- `x = ...` without an annotation updates the visible variable or creates a new one. With shadowing, the same line would have two meanings depending on the scope.
- Blocks capture by value, and assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`. A block parameter that hides an outer variable would make it unclear which `x` the block captured.
- One name means one variable in a scope. This helps agents write correct code on the first try and keeps diagnostics clear.
- The evaluation logs ([`eval-diagnostics.md`](eval-diagnostics.md)) show no `CHECK-SHADOWED-NAME` errors. The skill already tells agents that shadowing is not allowed, so this shows only that agents follow the rule without trouble, not that nobody wants shadowing.

**Also rejected:** binding the same name again with a new type in the same scope, like Rust's `let n = n.parse()`. Today a plain `n = <other type>` is `CHECK-TYPE-MISMATCH`, and an annotated `n: T = ...` on an existing name is `CHECK-ANNOTATION-ON-EXISTING`. Use two names instead:

```agentica
text = "42"
count = String.to_int!(text)
puts((count + 1).to_s)
```

## 15. Adapters and JSON inspection

Small language items for adapters (one interface, several backends), facades, and JSON of unknown shape. 15.1 and 15.3 serve adapters; 15.2 reads unknown JSON; 15.4 gives enums a JSON form, which typed decoding lacks today. Each lands in the evaluator and the VM in the same PR, with the grammar, the programming skill, the site docs and tests (roadmap Phase 10).

### 15.1 Calling `Fn` fields without `.call`

```agentica
struct Storage
  get: Fn[String, Result[String]]
  put: Fn[String, String, Result[Void]]
end

def getter(f: Fn[String, Result[String]]) -> Fn[String, Result[String]]
  return f
end

def putter(f: Fn[String, String, Result[Void]]) -> Fn[String, String, Result[Void]]
  return f
end

def valid_name?(name: String) -> Bool
  allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  return name != "" and String.split(name, "").all? do |c|
    String.contains?(allowed, c)
  end
end

def disk_storage(dir: String) -> Storage
  get = getter() do |key|
    if !valid_name?(key)
      return error("bad key")
    end
    File.read_text("#{dir}/#{key}", 1000)
  end
  put = putter() do |key, text|
    if !valid_name?(key)
      return error("bad key")
    end
    File.write_text("#{dir}/#{key}", text, 1000)
  end
  return Storage(get: get, put: put)
end

def memory_storage(items: Map[String, String]) -> Storage
  get = getter() do |key|
    Map.get(items, key)
  end
  put = putter() do |key, text|
    error("read-only")
  end
  return Storage(get: get, put: put)
end

def save_note(store: Storage, name: String, text: String) -> Result[Void]
  return store.put(name, text)   # today: store.put.call(name, text)
end
```

- If `s` is a struct and its field `put` has type `Fn[...]`, then `s.put(a, b)` calls it. It means the same as `s.put.call(a, b)`. It also works on a nested field (`app.store.put(a, b)`) and with no arguments (`s.reset()`).
- `s.put` without parentheses is still the field value, so it can be passed on or stored.
- A block is allowed: `s.put(a) do |x| ... end` passes the block as the last argument, the same as `s.put.call(a) do |x| ... end`.
- A block without parentheses is a call too: `s.run do |x| ... end`, where `run` is a `Fn` field, calls it with the block as its only argument, like `xs.each do ... end`. A bare `s.run` with no block and no parentheses is still the field value. In `case`, `while` and `for` headers a `do` belongs to the header and is never a block (as `grammar.md` says), so `for x in s.gen do` reads the field `s.gen`; write `(s.gen do ... end)` to call it.
- Structs have no user methods, so there is no ambiguity with them. If methods on user types ever land (§3, §7), that feature must decide the precedence; this plan does not. The only methods a struct has today are the builtin `to_s` and `inspect` of printable structs. Today `s.to_s` without parentheses reads a field named `to_s` if there is one, but `s.to_s()` with parentheses goes to method checking and calls the builtin. The new rule only adds a case: `s.name(...)` calls the field when `name` is a `Fn` field. A `Fn` field named `to_s` or `inspect` cannot clash with the builtin, because a struct with a `Fn` field has no `to_s` or `inspect` either, because a `Fn` is not printable. Today `s.put(a, b)` is `CHECK-UNKNOWN-METHOD` (with the help "put is a function field; call it with .put.call(...)"), so no valid program changes meaning.
- On a generic struct (15.3) the rule applies after substitution: for `b: Box[Fn[Int, Int]]`, `b.value(1)` calls the field.
- Arity and type errors are the same as for `.call`: a wrong number of arguments is `CHECK-ARITY`, a wrong argument type is `CHECK-TYPE-MISMATCH`. A name that is not a field, or a field that is not a `Fn`, stays `CHECK-UNKNOWN-METHOD` with today's help.
- **Adapter pattern:** a struct of `Fn` fields is the interface; a function such as `disk_storage(dir)` is one implementation, and its blocks capture `dir`. Code like `save_note` takes `Storage` and does not know the backend. The disk backend writes files under a directory and checks each key with its own copy of the allow-list check `valid_name?` before it builds a path (the facade's `valid_name?` is private to its module, so the adapter cannot call it from another file; it has its own copy or lives in the same module) (`error("bad key")` otherwise); its tests use a temporary directory. The memory backend is read-only: its map is fixed when it is created, `get` reads it, and `put` returns `error("read-only")`. A test can pass the memory backend to code that only reads, and the program passes the disk one. The two backends live in separate programs; see the "Done when" of [roadmap phase 10](roadmap.md#phase-10-adapters-and-json-inspection). A block can only be written as the last argument of a call, so each block goes through a small function that returns it (`getter`, `putter` above); standalone lambdas stay open (§3).
- **Facade pattern:** a file module that exports a few functions and hides the rest. It needs no new syntax:

  ```agentica
  # users.agc
  export struct User
    name: String
    age: Int
  end

  def valid_name?(name: String) -> Bool
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    return name != "" and String.split(name, "").all? do |c|
      String.contains?(allowed, c)
    end
  end

  export def save_user(dir: String, user: User) -> Result[Void]
    if !valid_name?(user.name)
      return error("bad user name")
    end
    return File.write_text("#{dir}/#{user.name}.json", JSON.encode(user), 1000)
  end

  export def load_user(dir: String, name: String) -> Result[User]
    if !valid_name?(name)
      return error("bad user name")
    end
    text = try File.read_text("#{dir}/#{name}.json", 1000)
    return JSON.decode(text, User)
  end
  ```

  Callers write `import "users.agc" as Users` and call `Users.load_user(dir, "ana")`; `valid_name?` stays hidden. A facade or adapter must check a name with an allow-list before it uses it in a path, as `valid_name?` does: the name is not empty and has only ASCII letters, digits, `-` and `_`. Otherwise it returns `error(...)`.
- **Limit:** values are immutable and blocks capture by value, so an in-memory adapter cannot change its own data. A memory adapter that writes needs a new struct per write (its `put` returns one, for example `Fn[String, String, MemoryStorage]`), or, later, blocks that capture a shared table (§13).
- Evaluator: it resolves a struct method call to the field call in the same checker-filled `resolved` slot it uses for builtin methods.
- VM: no new opcode. The checker records the call as an invoke of the field value, so lowering emits a field read and `call-value`, as for `.call`. It needs `.call` on the VM (7e PR 5e).

### 15.2 `JSON.kind`

```agentica
def count_numbers(j: Json) -> Int
  total = 0
  case JSON.kind(j)
    JsonValue.JsonInt(_) -> total = 1
    JsonValue.JsonBigInt(_) -> total = 1
    JsonValue.JsonFloat(_) -> total = 1
    JsonValue.JsonList(items) ->
      for item in items
        total = total + count_numbers(item)
      end
    JsonValue.JsonObject(fields) ->
      for key in fields.keys
        total = total + count_numbers(fields[key])
      end
    _ -> total = 0
  end
  return total
end
```

- `JSON.kind(j: Json) -> JsonValue`, also the method `j.kind`. It looks one level into a `Json` and never fails.
- `JsonValue` is a builtin enum:

  ```agentica
  enum JsonValue
    JsonNull
    JsonBool(Bool)
    JsonInt(Int)
    JsonBigInt(String)
    JsonFloat(Float)
    JsonString(String)
    JsonList(List[Json])
    JsonObject(Map[String, Json])
  end
  ```

- **Numbers** follow `JSON.int` and `JSON.float`, and `JSON.parse` does not change:
  The rule is by value, not by text:
  - `JsonInt(n)` for an exact integer that fits in a signed 64-bit `Int`. This is exactly when `JSON.int(j)` is `ok(n)`.
  - `JsonBigInt(text)` for any other exact integer. `text` is its decimal text, so it stays exact; `JSON.int` fails on it, as it does today.
  - `JsonFloat(x)` for a double, the value `JSON.float` returns.

  `JSON.parse` makes a double exactly for a number written with a fraction or exponent, so `3.0` and `1e2` are `JsonFloat` even when they are whole numbers; a number that is not finite is the existing error. Values from the builders and `JSON.from` follow the same rule: an `Int` is `JsonInt` and a `Float` is `JsonFloat`. So `kind` stays total.
- **Object order:** the keys of `JsonObject` use the same sorted order as `JSON.decode` into a `Map`: sorted by Unicode code point (typed decode in `src/json-typed.rkt` sorts with `symbol<?`; a byte-wise compare of UTF-8 text gives the same order). The text order is not kept, so `JSON.parse` does not change. The insertion order of an object made with the builder (`JSON.object`) is not kept either: `kind` gives its keys sorted too. Text order may come later if a real program needs it; it would need an ordered object representation in the evaluator.
- It works with the existing `case`, the branch check and bindings, with no grammar change. Variants are qualified like any enum (`JsonValue.JsonInt(n)`). `JsonValue` values are for reading: they have `to_s` and `inspect` like other enums. `JsonValue` stays out of all four JSON type functions: `JSON.encode` and `JSON.from` reject it with `CHECK-NOT-ENCODABLE`, and `JSON.decode` and `JSON.schema` with `CHECK-NOT-DECODABLE`; build Json with the builders, and use `Json` for free-form data.
- `JsonValue` becomes a reserved name: a user `struct JsonValue`, `enum JsonValue` or `import ... as JsonValue` is `CHECK-REDEFINED-NAME`. This is a breaking change; say so in the changelog.
- The recommended path is still `JSON.decode` into typed structs. `kind` is the low-level tool for unknown shapes: a generic pretty printer, a config with free-form values, or a reply whose shape depends on a field.
- Unlike Ruby's `case x when String`, a general `typeof` or a type-pattern `case` is not planned. Static types make the answer constant for every other value; `Json` is the only dynamic value, and `kind` covers it.
- Diagnostics: none new. A non-`Json` argument is `CHECK-TYPE-MISMATCH`; a missing variant is `CHECK-NON-EXHAUSTIVE-CASE`.
- Evaluator: `JsonValue` is the first builtin enum, so it needs a path in the checker's enum table and in the evaluator.
- Import linking (`src/modules.rkt`): it renames each module's names and rejects unknown aliases, so `JsonValue` needs a path there too, like the existing `Result` exception (`[(and (eq? kind 'enum) (string=? name "Result")) name]`). It covers enum patterns and constructors (`JsonValue.JsonInt(n)`), and the bare nullary form `JsonValue.JsonNull`, which arrives as a `type-expression` and is resolved there. Without it, linking renames these names or rejects them with `CHECK-IMPORT-NAME`.
- Planned tests: besides `case` over every variant and the number fixtures below, `JsonValue` used inside an imported module (patterns, a payload constructor and `JsonValue.JsonNull`), checked and run through an `import`.
- VM: needs the JSON PR (`docs/vm.md` §12.2 item 7). `JsonValue` is a builtin entry of the enum table with this fixed variant order, so `case` lowers as for user enums. Like a user enum, `JsonValue` is written to the bytecode Enums section only when a program uses it, so the file layout and the opcode meanings do not change and 10b needs no format bump. If the implementation ever needs a fixed index or a layout change, 10b bumps the format version itself (`docs/vm.md` §4). The JSON PR adds no placeholder for it. Numbers in the VM:
  - The VM Json tree already has a big-integer node kept as decimal text (`docs/vm.md` §5, Json row). An integer written without a fraction or exponent that is outside int64 is that node, and `JSON.kind` maps it to `JsonBigInt` with its exact decimal text.
  - A number with a fraction or exponent is a double (`JsonFloat`). A non-finite one, such as `1e400`, is the existing `JSON number is not finite` error.
  - The rule holds for every JSON builtin that reads the tree, not only `kind`: `JSON.float` on a big integer gives the same float as the evaluator (`exact->inexact`, and the same error when the result is not finite); `JSON.encode` writes it back as its exact decimal text; typed decode treats it as the evaluator does (an `Int` target fails, a `Float` target takes `exact->inexact` of it when that is finite).
  - `-0` is read as exact 0 by the evaluator, so it is `JsonInt(0)`. `-0.0` has a fraction, so it is a double, but Racket's `read-json` (Racket CS 9.3) drops the sign and reads it as `0.0`, so it is `JsonFloat(0.0)`. The VM must match both.
  - Planned differential fixtures: `9223372036854775808` and `-9223372036854775809` (both `JsonBigInt`), `-0` (`JsonInt(0)`), `-0.0` (`JsonFloat(0.0)`) and `1e400` (the error).

  `JSON.kind` is a builtin that builds the variant from the parsed node; lists and maps hold the child nodes as `Json` values without copying them.

### 15.3 Generic structs

```agentica
struct Box[T]
  value: T
end

struct Cache[V]
  items: Map[String, V]
  limit: Int
end

def main() -> Void
  b = Box(value: 1)                                 # Box[Int]
  puts(b.value + 1)                                 # b.value is Int
  c: Cache[Int] = Cache(items: {}, limit: 10)
end
```

- Same rules as generic enums: `struct Name[T, ...]` declares type parameters; their names may not repeat or reuse a reserved type name. Construction infers them from the field values; when it cannot (an empty list or map), it needs an expected type from an annotation, parameter, field or return. Type arguments are checked like enum type arguments.
- `Map` keys must still be `Int` or `String`. A type parameter used as a `Map` key (`items: Map[K, V]`) is rejected at the declaration with `CHECK-MAP-KEY-TYPE`, as for generic enums today.
- All rules apply after substitution. Field access returns the substituted type: `b.value` is `Int` for a `Box[Int]`. `printable-type?` is checked on the substituted type, so `Box[Int]` has `to_s` and `inspect`, and `Box[Fn[Int, Int]]` does not.
- An imported generic struct is written `M.Box[Int]`, as for enums. Import linking (`src/modules.rkt`) must carry the type parameters through: today its `struct-decl` case rewrites every field type through `resolve`, so a bare `T` would get the module prefix. It needs the same check as `rewrite-enum-type` does for enums (a parameter name with no type arguments stays as it is). Planned test: a generic struct declared in an imported module and used as `M.Box[Int]`.
- Diagnostics reuse the enum codes: a wrong number of type arguments, or a bare `Box` in a type, is `CHECK-UNKNOWN-TYPE`; a repeated or reserved parameter name is `CHECK-REDEFINED-NAME`; a parameter that cannot be inferred is `CHECK-ENUM-TYPE-INFERENCE` (the message names the struct); conflicting field types are `CHECK-TYPE-MISMATCH`.
- `CHECK-ENUM-TYPE-INFERENCE` is reused for structs and keeps its name; 10c adds a note about it to the diagnostics reference of the programming skill.
- They enable a reusable adapter: `struct Storage[T]` with `get: Fn[String, Result[T]]` and `put: Fn[String, T, Result[Void]]`, filled once per backend.
- JSON: `JSON.encode` and `JSON.from` work on any generic instance, struct or enum (with 15.4), whose fields or payloads are encodable after substitution, because encoding needs no `$defs`. Only `JSON.decode` and `JSON.schema` reject a generic instance, struct or enum, anywhere in the target, with `CHECK-NOT-DECODABLE`, until a real program needs it. The reason: `$defs` is keyed by the bare type name, so `Box[Int]` and `Box[String]` would collide. A direct target would also need type arguments in expression position (`Box[Int]` reads as indexing). A bare generic target with no type arguments, such as `JSON.decode(text, Box)` or `JSON.schema(Option)`, is `CHECK-UNKNOWN-TYPE`, as type resolution gives today.
- VM: no change. Type parameters exist only in the checker, as for generic enums; the struct table keeps field names and order.

### 15.4 JSON for enums

Today `JSON.decode` and `JSON.schema` take named structs only, and a struct with an enum field is `CHECK-NOT-DECODABLE`; `JSON.encode` rejects enums too (`CHECK-NOT-ENCODABLE`). Enums are the way to model "one of these shapes", so they need a JSON form. It uses tagged objects:

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

struct Drawing
  shapes: List[Shape]
end
```

```json
{"shapes": [{"tag": "Circle", "values": [2.0]}, {"tag": "Empty", "values": []}]}
```

- A variant is an object with `tag` (the variant name, without the enum name) and `values` (the payloads in order). `JSON.encode` and `JSON.from` always write both keys; `JSON.encode` text puts `tag` first. `JSON.decode` accepts a missing `values` for a nullary variant and ignores extra keys, as for structs.
- `JSON.encode` and `JSON.from` work on any user enum (not `JsonValue`) whose payloads are encodable, generic instances included (`Option[Int]`), because encoding needs no `$defs`.
- Only non-generic enums are decodable, and only when their payload types are. A generic enum instance such as `Option[Int]` anywhere in a decode or schema target is `CHECK-NOT-DECODABLE` (15.3 gives the reason); a bare `Option` is `CHECK-UNKNOWN-TYPE`. `Result` stays out. `JsonValue` stays out of all four functions (15.2).
- The decode target may be a non-generic enum: `JSON.decode(text, Shape)`.
- Errors return `error(...)` with the same paths as struct fields (`shapes[0].values[1]`): an unknown tag, a missing `tag`, a wrong number of values, or a wrong value type. No new code: an enum with a non-decodable payload is `CHECK-NOT-DECODABLE`.
- `JSON.schema(Shape)` accepts the same enums as decode and describes the tagged-object form. It writes a `oneOf` with one object per variant and its `tag` as a one-value `enum` (`{"enum": ["Rect"]}`), which also works in draft-04. The schema is accepted by every draft; per-payload types are checked from 2020-12 (`prefixItems`):
  - `values` is an array whose length is fixed with `minItems` and `maxItems` (the number of payloads).
  - `prefixItems`, with one schema per payload, is added only when the variant has payloads. There is no `"items": false`.
  - A nullary variant gets `"values": {"type": "array", "maxItems": 0}`, and `values` is not in its `required`, since decode accepts a missing `values`.
  - Enums go into `$defs` like structs. The root gets no `$schema`; that stays as today.

  For `Shape`, the `Rect` and `Empty` entries of the `oneOf`:

  ```json
  {"type": "object",
   "properties": {"tag": {"enum": ["Rect"]},
                  "values": {"type": "array", "minItems": 2, "maxItems": 2,
                             "prefixItems": [{"type": "number"}, {"type": "number"}]}},
   "required": ["tag", "values"]}
  {"type": "object",
   "properties": {"tag": {"enum": ["Empty"]},
                  "values": {"type": "array", "maxItems": 0}},
   "required": ["tag"]}
  ```
- VM: lands with or after the JSON PR (`docs/vm.md` §12.2 item 7); the type table gets an enum entry with each variant's payload types. If the JSON PR's type table has no enum entry kind, 10d adds it and bumps the format version (`docs/vm.md` §4); the JSON PR adds no placeholder for it.

### 15.5 Not planned

Structural interfaces (Go-style, where a type fits because it has the right methods) are not planned: user types have no methods, §6 already rules out interfaces and traits, and a struct of `Fn` fields (15.1) is an interface checked by name. `respond_to?` is not planned: the checker knows every field and method of a value, so the answer is constant, and a run-time check would only hide a type error. Reflection (listing a struct's fields, building a value from a type name, calling a function by a name in a string) is not planned: it breaks static checking and makes the VM keep names and types at run time; use `JSON.from` to see a value's fields and a `Map[String, Fn[...]]` to dispatch by name.

## 17. Optional and nullable JSON fields

APIs with JSON Schema inputs (tool calls, PATCH bodies, config files) often tell three states of a key apart: the key is absent, the key is `null`, or the key has a real value. Typed JSON cannot show this today. `JSON.decode` (`src/json-typed.rkt`) fails on a missing key ("required field") and on `null`; `JSON.schema` lists every field in `required`; `JSON.encode` and `JSON.from` always write every field. `nil` does not help: `Nil` is not a nullable wildcard (`grammar.md`). The only way is dynamic `Json`: `JSON.get` returns an error for an absent key and `JSON.null?` finds `null`. This section adds a typed way. It is roadmap item 10e.

```agentica
struct UpdateUser
  name: JsonField[String]
  age: JsonField[Int]
end

def describe_age(age: JsonField[Int]) -> String
  text = ""
  case age
    JsonField.Absent -> text = "age: keep"
    JsonField.Null -> text = "age: clear"
    JsonField.Value(n) -> text = "age: set to #{n}"
  end
  return text
end

def show(text: String) -> Result[Void]
  update = try JSON.decode(text, UpdateUser)
  puts(describe_age(update.age))
  name = ""
  case update.name
    JsonField.Value(n) -> name = "set to #{n}"
    _ -> name = "keep"          # this API treats null like absent
  end
  puts("name: #{name}")
  puts(JSON.encode(update))
  return ok()
end

def main() -> Void
  for text in ["{}", "{\"age\": null}", "{\"name\": \"Ana\", \"age\": 30}"]
    Result.unwrap!(show(text))
  end
  reply = UpdateUser(name: JsonField.Value("Bo"), age: JsonField.Null)
  puts(JSON.encode(reply))
end
```

Output:

```output
age: keep
name: keep
{}
age: clear
name: keep
{"age":null}
age: set to 30
name: set to Ana
{"name":"Ana","age":30}
{"name":"Bo","age":null}
```

- **The type.** `JsonField[T]` is a builtin generic enum:

  ```agentica
  enum JsonField[T]
    Absent
    Null
    Value(T)
  end
  ```

  The variants are always qualified (`JsonField.Value(x)`), so they do not clash with user enums. `Absent` and `Null` are nullary and need an expected type, like any nullary variant of a generic enum (`CHECK-ENUM-TYPE-INFERENCE` otherwise); a struct field gives one.
- **Decode** (`JSON.decode`), for a struct field of type `JsonField[T]`: a missing key gives `Absent`; JSON `null` gives `Null`; any other value is decoded as `T` and gives `Value(...)`. Errors keep today's paths: `Value` adds no path step, so a bad `age` is `age: expected signed 64-bit Int`, and a bad nested field under `address: JsonField[Address]` is `address.zip: expected String`. Fields that are not `JsonField` still fail with "required field" when missing. Extra keys are still ignored.
- **Encode** (`JSON.encode`, `JSON.from`): `Absent` leaves the key out, `Null` writes `null`, `Value(x)` writes `x` as today. The other keys keep struct declaration order. `Value(nil)` writes `null` too, as `nil` does today; only decode tells `Null` apart, and it never makes `Value(nil)`, because `Nil` is not decodable.
- **Schema** (`JSON.schema`): a `JsonField[T]` field is left out of `required`, and its property schema is `{"anyOf": [<schema of T>, {"type": "null"}]}`. `anyOf` and the `"null"` type work in every draft, and the form is the same when `T` is a `$ref` to a struct. When no field of a struct is required, `required` is left out, because draft-04 needs a non-empty list. For `UpdateUser`:

  ```json
  {"type": "object",
   "properties": {"name": {"anyOf": [{"type": "string"}, {"type": "null"}]},
                  "age": {"anyOf": [{"type": "integer",
                                     "minimum": -9223372036854775808,
                                     "maximum": 9223372036854775807},
                                    {"type": "null"}]}}}
  ```

- **Round trip:** decoding an object and encoding the result gives back the same object, up to key order (the encoded text follows declaration order). An absent key stays absent and a `null` stays `null`.
- **`case`:** the three variants need three arms, or a `_` arm. `_` is how a program merges absent and null when its API does not tell them apart.
- **Where it is allowed in JSON.** In the type of a JSON builtin target (`JSON.decode`, `JSON.schema`) or argument (`JSON.encode`, `JSON.from`), `JsonField[T]` is allowed only as the direct type of a struct field. Absent and null are about an object key, and only struct fields are object keys with a fixed name. Everywhere else in that type it is `CHECK-JSON-FIELD-PLACE` (new code):
  - an item of a list (`List[JsonField[Int]]`) or a map value (`Map[String, JsonField[Int]]`): a list has no key to leave out, and a map already shows absence by not having the key;
  - a nested `JsonField[JsonField[T]]`: there is no fourth state;
  - an enum payload, once enums have a JSON form (§15.4);
  - the whole argument of `JSON.encode` or `JSON.from` (`JSON.encode(f)` where `f: JsonField[Int]`).

  A decode or schema target cannot be `JsonField` itself: the checker takes only a type name there (`checker.rkt`, the `json-decode json-schema` rule), and a bare `JsonField` with no type arguments is `CHECK-UNKNOWN-TYPE`, as for any generic name today. `T` itself must be decodable (or encodable) as today, or the call is `CHECK-NOT-DECODABLE` (or `CHECK-NOT-ENCODABLE`). The check walks the type the way `decodable-type?` and `encodable-type?` do now, with one more argument that says whether the type is the direct type of a struct field; it reports the first problem it finds, at the span of the target or argument, and the message names the struct and field (or "list item", "map value") where the `JsonField` sits.
- **Not a generic exception for `$defs`.** §15.3 and §15.4 keep generic instances out of decode and schema because `$defs` is keyed by the bare type name. `JsonField[T]` is the one generic instance they accept: it never gets a `$defs` entry, since its schema is the inline `anyOf` above.
- **Outside JSON** `JsonField[T]` is an ordinary enum value: locals, parameters, returns, lists and maps may hold it, and it is printable when `T` is (`JsonField.Value(30)`, `JsonField.Absent`). Like every enum it has no `==`; use `case`.
- **Not `Option`.** `JsonField` is only for JSON shapes. `Option` stays a free name, since many programs declare their own `enum Option[T]`; the open question of a builtin `Option[T]` (roadmap, "Later extensions") is not changed by this.
- **Reserved name.** `JsonField` becomes a reserved type name: a user `struct JsonField`, `enum JsonField` or `import ... as JsonField` is `CHECK-REDEFINED-NAME`. This is a breaking change; say so in the changelog.
- **Builtin enum path.** `JsonField` reuses the builtin-enum path that `JsonValue` adds in §15.2 (10b): the checker's enum table, the evaluator, and `src/modules.rkt` import linking for patterns, constructors and the bare nullary forms `JsonField.Absent` and `JsonField.Null` (which arrive as `type-expression`s). It adds one thing: `JsonField` has a type parameter, so its table entry is generic like a user generic enum.
- **Evaluator:** the decode field loop and the schema object in `src/json-typed.rkt`, and `json-data` and `encode-json` in `src/evaluator.rkt`, handle a field whose declared type is `JsonField`. Nothing else changes.
- **Diagnostics:** one new code, `CHECK-JSON-FIELD-PLACE`. A missing variant is `CHECK-NON-EXHAUSTIVE-CASE`; a wrong payload type is `CHECK-TYPE-MISMATCH`.
- **VM:** needs the JSON PR (`docs/vm.md` §12.2 item 7) and its type table. `JsonField` is a builtin entry of the enum table with the fixed variant order `Absent`, `Null`, `Value`, written to the Enums section only when a program uses it, as for `JsonValue`. Typed decode, schema and encode need to know that a struct field is a `JsonField[T]`: the type table gets an entry kind for it that points to `T`, like the List and Map entries. If the JSON PR's type table has no such kind, 10e adds it and bumps the bytecode format version (`docs/vm.md` §4); otherwise the layout does not change and there is no bump. The JSON PR adds no placeholder for it.
- **Planned tests:**
  - decode of the three states (key absent, `null`, a value), in the evaluator test and as a site example;
  - path errors through a nested struct (`address: JsonField[Address]` with a bad `address.zip`) and a bad value type (`age: "x"`);
  - encode and `JSON.from`: `Absent` leaves the key out, `Null` writes `null`, `Value` writes the value;
  - schema: the `JsonField` field is not in `required`, its property is the `anyOf` with `{"type": "null"}`, a `$ref` inside `anyOf` for a struct `T`, and no `required` key when no field is required;
  - round trip: decode then encode gives back the same object up to key order, for absent, null and value;
  - `CHECK-JSON-FIELD-PLACE` for a list item, a map value, `JsonField[JsonField[Int]]` and a top-level `JSON.encode` argument; `CHECK-REDEFINED-NAME` for a user type named `JsonField`;
  - `JsonField` used in an imported module (field types, patterns, `JsonField.Value(x)`, bare `JsonField.Absent` and `JsonField.Null`), checked and run through an `import`;
  - evaluator against VM (`tests/vm-diff-test.rkt`) once the VM has JSON.
