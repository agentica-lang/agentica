# Agentica: future grammar

Status: proposals only. This document is not normative; implemented language behavior is specified in [`grammar.md`](grammar.md).

Working rule: when a phase of the [`roadmap.md`](roadmap.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

Section 14 records ideas that were decided or rejected, so they are not proposed again. Section 18 records an implementation decision that is deferred. Sections 19 (SIMD in the VM), 21 (VM layers) and 22 (JIT) are implementation proposals with no language change. Section 23 (binary data) adds `Int` and `Float` builtins and the `std/binary` module, with no grammar change. Section 24 (logging and debugging) adds the `std/log` module, stack traces on runtime errors and tracing inside the VM, with no grammar change.

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
- **Ranges, sets and queues:** ranges are in `grammar.md` (8a); sets and queues are planned in [section 12](#12-data-structures). Meanwhile use `Map[T, Bool]` and `std/queue`.
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

The implementation uses ordinary coroutine threads. Racket CS 9.3 also supports parallel thread pools; places are not the only multicore option. See [Racket threads](https://docs.racket-lang.org/reference/threads.html). In the evaluator, add CPU parallelism only after measuring a concrete workload and reviewing shared state. The VM is designed for multicore from its first tasks PR (`docs/vm.md` §10.2.3), but N>1 schedulers are gated: the roadmap builds them only if the server measurement asks for it (roadmap order step 11).

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

Implemented in 8a: the rules are in `grammar.md` ("Ranges"). This section keeps the design notes.

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
- `std/queue` stays, deprecated: `Queue` becomes a reserved name, so `import "std/queue.agc" as Queue` would fail with `CHECK-REDEFINED-NAME`. 8c renames the documented alias to `StringQueue` in `README.md`, `examples/queue.agc`, `docs/grammar.md`, the programming skill's modules reference, `tests/modules-test.rkt` and `tests/stdlib-distribution-test.rkt`, keeps `stdlib/queue.agc` and its entry in `src/stdlib.rkt` (so the `std/` path and its tests keep their coverage even when it is the only embedded module), keeps the `examples/queue.agc` smoke runs in `.github/workflows/ci.yml` and `release.yml` working, and notes the break in the changelog. `std/queue` is removed later, in its own PR with a changelog note, and only when both hold: 8c has landed (so `Queue[T]` replaces it), and another `std/` module (such as `std/binary`, §23) keeps the `std/` path and its tests covered. Neither 8c nor the PR that adds another `std/` module removes it.

### 12.4 Faster lists

Not a new type: `List` keeps its API and meaning, and only its representation changes. Today `List.append` copies the list (O(n)), and indexing is O(n) in the evaluator. A persistent vector (a 32-way trie with a tail buffer, as in Clojure and Scala) makes `append`, `set` and indexing O(log32 n), near constant, and keeps old versions unchanged. Both backends change in the same PR; output, step counts and diagnostics stay the same. Measure with `benchmarks/` before and after.

### 12.5 Later

Each needs a real program first.

- **Tuples:** `(Int, String)` values and destructuring, to return two values without a struct; then `Queue.pop`.
- **`Bytes`:** binary data instead of `List[Int]` (`IO.read_bytes`, `String.from_bytes`). Until then, `std/binary` (§23) packs numbers into `List[Int]`; it does not replace `Bytes`. When `Bytes` lands, the `std/binary` API moves to `Bytes` in the same change as the `*_bytes` builtins.
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
  - VM: a table call does not yield, so with one scheduler (`--schedulers 1`, and the first tasks PR of 7h) it is atomic. Once N schedulers run in parallel (`docs/vm.md` §10.2.3), each table call needs a lock, an owner scheduler, or a persistent structure installed with compare-and-swap, as the evaluator does.
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
- JSON: `JSON.encode` and `JSON.from` work on any generic instance, struct or enum (with 15.4), whose fields or payloads are encodable after substitution, because encoding needs no `$defs`. Only `JSON.decode` and `JSON.schema` reject a generic instance, struct or enum, anywhere in the target, with `CHECK-NOT-DECODABLE` (except `JsonField[T]` as a direct struct field, §17), until a real program needs it. The reason: `$defs` is keyed by the bare type name, so `Box[Int]` and `Box[String]` would collide. A direct target would also need type arguments in expression position (`Box[Int]` reads as indexing). A bare generic target with no type arguments, such as `JSON.decode(text, Box)` or `JSON.schema(Option)`, is `CHECK-UNKNOWN-TYPE`, as type resolution gives today.
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
- Only non-generic enums are decodable, and only when their payload types are. A generic enum instance such as `Option[Int]` anywhere in a decode or schema target is `CHECK-NOT-DECODABLE` (except `JsonField[T]` as a direct struct field, §17; 15.3 gives the reason); a bare `Option` is `CHECK-UNKNOWN-TYPE`. `Result` stays out. `JsonValue` stays out of all four functions (15.2).
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

## 16. Binary serialization (CBOR)

The counterpart of Erlang's `term_to_binary` and `binary_to_term`: a typed binary form of Agentica values, in CBOR ([RFC 8949](https://www.rfc-editor.org/rfc/rfc8949)). It lands only when a real program needs it (roadmap Phase 11).

### 16.1 Motivation

JSON covers interop with other programs. A binary form keeps what JSON loses or bends:

- `Map[Int, V]`: JSON object keys are always text, so `JSON.encode` rejects Int keys today.
- Exact `Float` bits: JSON goes through decimal text and cannot write infinities.
- `nil` as its own value, and enums as a plain array instead of an object convention.

It is also smaller and faster to read and write. Uses: a disk cache, messages between Agentica processes (over `Process.spawn` pipes), and later a snapshot of a shared table (§13) through `Table.to_map`.

### 16.2 API

```agentica
struct Entry
  hits: Map[Int, Int]
  score: Float
end

def round_trip(entry: Entry) -> Result[Entry]
  data = try Term.encode(entry)      # Bytes
  return Term.decode(data, Entry)
end

def main() -> Void
  IO.inspect(round_trip(Entry(hits: {1: 10, 2: 20}, score: 0.5)))
end
```

```text
Term.encode(value: T) -> Result[Bytes]
Term.decode(data: Bytes, type: T) -> Result[T]
```

- `encode` returns a `Result` because it can fail on data the checker cannot see: a value nested too deep, with too many items, or with bytes past the 64 MiB limit (16.5). It never halts on these.
- The second argument of `decode` is a static type argument, not a value, as in `JSON.decode(text, User)`: a type name written in argument position. It is checked at compile time and has no run-time value.
- Allowed types are the same for both functions: the rule of 16.3. The one extra limit is syntax: the direct `decode` target is written as a bare name, so it is a named non-generic struct or a named non-generic enum. Types inside it (fields, payloads, list elements, map keys and values) follow 16.3 in full, generic instances included.
- There is never an untyped decode. Erlang's `binary_to_term` is a known attack vector: it can create atoms until the atom table is full, build functions, and allocate huge terms. Here the target type decides what is accepted, and nothing outside it is ever built.
- No method form (`value.to_cbor`). JSON has no `.to_json` either, and structs and enums have no methods. One spelling is easier for agents.
- The module is named for what it stores, not for the format. `Term` becomes a reserved type and module name: a user `struct Term`, `enum Term` or `import ... as Term` is `CHECK-REDEFINED-NAME`. This is a breaking change; say so in the changelog.

### 16.3 What can be serialized

The same data rule as printing: no `Fn`, `Task`, `Table` or resource handle (`FileHandle`, `Process`, `Socket` and the rest), at any depth.

- The check is a new predicate in `src/checker.rkt`. `printable-type?` (the deep walk that §13 uses for table values) only gives the base list of allowed and denied leaf types; it cannot be reused as is, for two reasons. It accepts `Json`, `Result` and type variables, which Term must reject. And its `seen` key is `(kind . name)`, without the type arguments, so once it has walked `Box[Int]` it would skip `Box[String]` inside it as already seen. The new walk looks through list elements, `Map` keys and values, struct fields and enum payloads, and for a generic instance it first substitutes the instance's type arguments into the field and payload types, then recurses into the result.
- Recursion is cut off with a `seen` set keyed on the substituted type: its kind (struct or enum), its name and its type arguments. A recursive type stops there: for `enum Tree[T]` with a payload `Node(List[Tree[T]])`, the walk of `Tree[Int]` stops when it meets `Tree[Int]` again, while `Box[Int]` and `Box[String]` are still checked apart.
- On top of the base list, `Json`, `Result`, `Void` and `Fn` are rejected at any depth of the type, not only at the top: `Box[Json]`, a field `items: List[Result[Int]]` and a payload `Map[String, Fn[Int, Int]]` all fail. `Json` has its own text form (`JSON.encode` it to a `String` first). `Result` is for error flow, not stored data (use a user enum); `printable-type?` accepts it, so this walk must reject it itself.
- **Concrete types only:** the argument of `encode` must have a concrete static type, with every type parameter known, as `JSON.encode` requires today (its `encodable-type?` rejects a type variable). The checker already gives this at every call site: there are no user generic functions, a constructor whose type parameters cannot be inferred is `CHECK-ENUM-TYPE-INFERENCE`, and an empty `[]` or `{}` with no expected type is `CHECK-EMPTY-LIST-TYPE` or `CHECK-EMPTY-MAP-TYPE`. If a type variable ever reaches `Term.encode` or a `decode` target (for example once generic functions exist), it is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`. Only type variables left after substitution are rejected: the `T` in the declaration of `Box[T]` is fine when the instance is `Box[Int]`. Note that `printable-type?` accepts a type variable, so this walk must reject it itself. Encode never falls back to the run-time shape of the value.
- Codes: `Term.encode` on a type that fails the rule is `CHECK-NOT-ENCODABLE`; a `Term.decode` target that fails it is `CHECK-NOT-DECODABLE`. The span is on the argument, as for JSON.
- Unlike JSON, `Map` keys may be `Int`. Key types stay `Int` or `String` (`CHECK-MAP-KEY-TYPE`), so nothing new is needed there.
- `Nil` is allowed, as a field type or a payload.
- **Generic instances:** both functions take generic instances (`Option[Int]`, `Box[String]`) inside the type, checked after substitution (see the walk above). JSON decode rejects them only because its schema keys `$defs` by the bare type name, so `Box[Int]` and `Box[String]` would collide (§15.3). CBOR has no schema: the decoder walks the substituted type, which the checker knows in full. A generic instance as the direct `decode` target stays out: `Term.decode(data, Option[Int])` needs type arguments in expression position (`Option[Int]` reads as indexing), and a bare `Option` is `CHECK-UNKNOWN-TYPE`, as today. Wrap it in a struct.

### 16.4 Format mapping

| Agentica | CBOR |
|---|---|
| `Int` | major type 0 (`n >= 0`) or 1 (`n < 0`) |
| `Float` | always a 64-bit float (major type 7, additional info 27) |
| `String` | text string (major type 3) |
| `Bool` | simple values `false` (0xF4) and `true` (0xF5) |
| `nil` | simple value `null` (0xF6) |
| `List[T]` | array (major type 4) |
| `Map[K, V]` | map (major type 5), in insertion order |
| struct | map keyed by field name, in declaration order |
| enum | 2-element array `[tag, [values...]]` |
| `Bytes` | byte string (major type 2) |

- **Int:** decode rejects values outside signed 64-bit (`major 0` above `2^63 - 1`, `major 1` below `-2^63`). Bignum tags (2, 3) are rejected like any tag.
- **Float:** always 8 bytes, so the bits are exact and a `Float` never comes back as an `Int`. Infinities and NaN can occur in Agentica values: an overflow gives `+inf.0`, and `inf - inf` gives NaN (`grammar.md` says that a NaN is not equal to itself). They are written as IEEE 754 values, and `-0.0` keeps its sign. Every NaN is written as the quiet NaN `0x7FF8000000000000`, so both backends give the same bytes whatever NaN payload the host makes. Decode reads a `Float` only from the 8-byte form; half and single floats are rejected.
- **String:** invalid UTF-8 (overlong forms, surrogates, code points above U+10FFFF, truncated sequences) is rejected on decode, with the same rule as the `.agcb` loader (`docs/vm.md` §8).
- **Map:** encode keeps insertion order and decode keeps the order of the bytes, so a round trip keeps the order (`JSON.decode` sorts keys instead). Duplicate keys are rejected on decode. Keys must match `K`: text strings for `String`, major 0/1 for `Int`.
- **Struct:** a map from field name (text string) to value, not an array in field order. An array is smaller, but any change of fields breaks old data, and when two fields have the same type it breaks it silently: the values swap. Decode accepts the keys in any order. Duplicate keys are rejected, as for `Map`, whether or not the field is known: two equal keys that the struct does not have are an error too. Inside an ignored value, maps are not checked for duplicate keys; they are only read with the size, depth and item checks (16.5). What a change of the struct does to old data:
  - **Removing or reordering fields is safe:** fields are keyed by name, and extra keys are ignored on decode, as in `JSON.decode`.
  - **Adding a field breaks old data:** there are no field defaults, and a missing field is an error. Old bytes do not have the new key, so they no longer decode with the new type. 16.6 says how to handle it.
- **Enum:** a CBOR array of exactly 2 items, `[tag, values]`:
  - `tag` is the variant name without the enum name, as a text string: `"Circle"`, not `"Shape.Circle"`.
  - `values` is a CBOR array that holds the payloads in declaration order, each in the form of its own type. A nullary variant has an empty array: `["Empty", []]`. The array is always there, also when it is empty.
  - For `Circle(2.0)` of `enum Shape`: `["Circle", [2.0]]`, which is the bytes `82 66 "Circle" 81 FB 4000000000000000`.
  - Decode reads the tag, finds the variant in the target enum (the static type at that point), and then reads exactly as many values as that variant has payloads, each against its payload type. An unknown tag, a values array of the wrong length, a missing values array, or an outer array that does not have exactly 2 items is an error.
  - Error paths for enum payloads are `<enum path>.values[i]` (for example `shapes[0].values[1]`), so they read the same as the JSON form.
  - This is the same tag and values order as the JSON form of enums (`{"tag": ..., "values": [...]}`, §15.4), written as an array instead of an object. The two must not drift apart: if §15.4 changes its tag rule, this section changes with it.
- **Deterministic encoding** (RFC 8949 §4.2): the shortest form of every integer and length head, and definite lengths only, so the same value, built the same way, gives the same bytes. "Built the same way" matters for maps, whose insertion order is kept: `{1: 10, 2: 20}` and `{2: 20, 1: 10}` hold the same entries but give different bytes. `0.0` and `-0.0` encode differently too, since the sign bit is kept. Two rules of §4.2.1 are not followed, on purpose: map keys keep insertion order (an Agentica `Map` is ordered, so the order is part of the value), and floats always take 8 bytes (so `Float` bits are exact).
- **Decode accepts only what encode writes**, with one freedom: struct keys may come in any order, and extra struct keys are ignored. It accepts only shortest heads, definite lengths, 8-byte floats, the one NaN above, and no tags at all. It rejects indefinite lengths, every tag, other simple values (`undefined` and the rest), a non-shortest head, and trailing bytes after the value. An ignored struct value is still read and checked as well formed (heads, lengths, no tags, valid UTF-8, the depth limit), only its type and duplicate map keys are not checked. Reading CBOR from other programs is not a goal; JSON covers interop.
- **Round trips:** `decode(encode(v))` gives `v`, compared by bytes or by printed output (`==` does not hold for a NaN). Every NaN comes back as the one canonical NaN above, so its bits are not kept; all other `Float` bits are exact. Whatever `encode` returns as `ok`, `decode` reads with the same type, with no extra condition, because encode keeps the same depth, item and size limits (16.5). In the other direction, `encode(decode(b))` gives back exactly `b` only when `b` is canonical, that is, bytes that `Term.encode` wrote. For any other input that decode accepts, the bytes are the same except for reordered or ignored struct keys: the struct keys come back in declaration order and the ignored keys are gone.

### 16.5 Untrusted input

`Term.decode` treats its bytes like the `.agcb` loader treats a file (`docs/vm.md` §8): they may come from another process or a file anyone could write.

- **Depth:** at most 10,000 levels, the same number as the call depth limit. Depth counts Agentica value nesting, not CBOR nesting:
  - The top value is at depth 1. A value inside a `List`, `Map`, struct or enum (an element, a key or value, a field, a payload) is one level deeper than that container. No value may be deeper than 10,000.
  - An enum is one level, though it is two CBOR arrays: the outer `[tag, values]` array and its inner `values` array together count once. Take `struct W` with one field `v: Option[Option[Int]]`, holding `W(v: Some(Some(1)))`: the struct is at depth 1, the outer `Some` at depth 2, the inner `Some` at depth 3 and the `1` at depth 4; counted by CBOR arrays and maps, the `1` would be at depth 6.
  - Encode and decode count the same way, so whatever `encode` writes, `decode` reads within the depth limit. Decode knows where an enum starts from the target type.
  - An ignored struct value (16.4) has no Agentica type, so there each CBOR array or map counts as one level, from the depth of the struct.
  - Depth is checked when a container is entered, before any of its items are read. A value at depth 10,000 is accepted; one at depth 10,001 is an error.
  - The VM walks with an explicit stack, never with C recursion (`docs/vm.md` §7.3).
- **Lengths before allocation:** every length is checked against the bytes left before anything is allocated. Each item takes at least one byte, so an array of `n` items needs at least `n` bytes left, a map of `n` entries at least `2n`, and a byte or text string exactly its length. All sums use `uint64_t` and the form `size > limit - total`.
- **Item cap:** this check alone does not keep memory small. One input byte (an empty array, `0xF6`, a small Int) can become a value that takes some tens of bytes in memory, so 64 MiB of input could build a few GiB. So decode also counts the values it reads: every Agentica value is one item. That is the top value (for example the top struct), each struct field value, each list element, each map key and each map value, each enum value (its outer `[tag, values]` array and its `values` array count as one item together) and each payload value. Inside an ignored struct value, which has no Agentica type, every CBOR item counts as one. When the count passes `TERM_MAX_ITEMS` = 4,000,000, decode stops with `$: too many items`. Both backends share this constant, and encode counts the same way (below). So `Wrap(items: xs)` with `xs: List[Int]` of `n` elements has 2 + `n` items (the struct, the field value `xs`, and the `n` elements): the largest list that fits is 3,999,998 elements, and one more is `$: too many items`. For more data, split it into chunks and encode each chunk as its own value. In the worst case that is about 4,000,000 times the size of the largest small value (some hundreds of MiB), plus strings and byte strings, which are bounded by the input (a Racket string holds 4 bytes per character, so at most 4 times its bytes).
- **Total size:** input above 64 MiB is an error before any reading.
- **Ignored values count too:** an ignored struct value (16.4) is read in full, so its bytes count toward the size and length checks, its nesting toward the depth limit, and its items toward the item cap, like any other value.
- **Errors are Results:** every problem returns `error(...)`, never a runtime diagnostic, with the path style of `JSON.decode`: `<path>: <reason>`, lowercase, with no final period. The root is `$`; below it the path starts with the first field, index or key, with no `$.` prefix, exactly as `JSON.decode` writes it (`shapes[0].values[1]`, `hits[3]`, `users["ana"].age`). Examples: `$: trailing bytes after the value`, `users[2].name: expected String`, `items: length is larger than the input`, `$: depth limit exceeded`, `$: too many items`, `$: indefinite length is not allowed`, `$: tags are not allowed`, `score: expected a 64-bit Float`, `shapes[1]: unknown tag "Triangle"`, `shapes[0].values: expected 2 values, found 1`.
- **Map keys in paths:** an `Int` key is written in decimal (`hits[3]`). A `String` key is written in double quotes with JSON string escaping: `\"` and `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, any other code point below U+0020 as `\u00XX` with lowercase hex, and every other character as is, in UTF-8 (`users["a\"b"]`). Today `JSON.decode` (`src/json-typed.rkt`) writes the key with Racket's `~s`, which differs for some characters (`\e`, `\u007F`, `\u200B`); the PR that lands this section moves `JSON.decode` to the same rule, and from then on both decoders, on both backends, use it.
- **Paths are built only on error:** while walking, each backend keeps a stack of path segments (a field name, an index or a key) and pushes and pops one per level. The path text is joined from the stack only when an error happens, never rebuilt at every level, so the cost stays linear in the input.
- **Depth and item-cap errors use the root path:** `$: depth limit exceeded` and `$: too many items`, in both directions and on both backends, with no deeper path. All other errors keep the full path.
- **Encode keeps the same limits and returns errors too:** a value deeper than the depth limit, with more than `TERM_MAX_ITEMS` values (counted as decode counts them), or whose bytes would pass 64 MiB, returns `error(...)`. The depth error is `$: depth limit exceeded` and the item error is `$: too many items`, as on decode; the size error has the path of the first value that crosses the limit. Examples: `$: depth limit exceeded`, `$: too many items`, `cache["big"]: encoded size is larger than 64 MiB`. It never halts: unlike a non-finite Float in `JSON.encode` (`RUNTIME-JSON-ENCODE`), these limits depend on the size of the data, which a program cannot easily check before the call. Encode stops writing as soon as a limit is passed, so it never builds more than 64 MiB. So whatever `encode` returns as `ok`, `decode` reads with the same type, with no extra condition. Only a named struct or enum can be the `decode` target (16.2), so a top-level value of another type (`List[Int]`, `Int`, `nil`) must be wrapped in a struct on both sides: encode `Wrap(items: xs)`, decode with `Wrap`.

### 16.6 Versioning

No version prefix and no self-describing tag (55799). The type is the schema. A prefix would cost bytes in every message and would still not say which type to decode into. If the mapping ever changes, that is a new function, not a flag in the data.

- **Put a `version: Int` field in the top struct from the first release.** Data written later can then say which shape it has.
- **To add a field** (which breaks old data, 16.4): keep the old type, say `CacheV1`, next to the new `CacheV2`. Decode with `CacheV2`; on error, decode again with `CacheV1` and convert the result to `CacheV2`. The retry works the other way too, because extra keys are ignored: `CacheV1` reads `CacheV2` bytes. Check `version` after the decode to tell the shapes apart when both decode.

### 16.7 Backends

- **Evaluator:** a small codec in Racket, in its own module (for example `src/term.rkt`), with no library. CBOR is small: one head byte, then 0, 1, 2, 4 or 8 bytes of argument.
- **VM:** an in-house C codec in `vm/`, with no new dependency. It needs the VM maps (`docs/vm.md` §12.2 item 5d) and `Bytes` on the VM. It lands with the evaluator codec in one PR.
- **Same bytes:** both backends give byte-identical output and the same error messages for the same input. `tests/vm-diff-*-test.rkt` checks it.
- **Tests:**
  - round trips: `decode(encode(v))` gives `v`; `encode(decode(b))` gives `b` for canonical `b`; for `b` with reordered or extra struct keys it gives the canonical bytes;
  - the RFC 8949 Appendix A vectors that fit the mapping, as fixed bytes in `tests/fixtures/`; they come from the RFC, not from our encoder, so they are the independent counterpart;
  - depth: an enum nested 10,000 levels encodes and decodes, and one more level is an error on both sides;
  - encode errors: a value past the depth limit returns `$: depth limit exceeded`, one with more than `TERM_MAX_ITEMS` values returns `$: too many items`, and one past 64 MiB returns its path;
  - item cap boundary: `Wrap(items: xs)` with 3,999,998 elements in `xs` round trips, and with 3,999,999 elements it is `$: too many items`, both on encode and on decode (the decode input built by hand);
  - hostile input: truncation at every byte, lengths larger than the input, depth one above the limit, more than `TERM_MAX_ITEMS` values (for example 4,000,001 one-byte items, also inside an ignored struct value), duplicate map and struct keys (also a duplicate struct key that the struct does not have), tags, indefinite lengths, non-shortest heads, invalid UTF-8, Ints outside int64, and trailing bytes. The VM loader fuzzer (`make vm-fuzz`) gets a decode target too.
- **Framing:** decode rejects trailing bytes, so a stream of messages needs framing. A message can be up to 64 MiB, but `Process.send_bytes` and `TCP.send_bytes` take at most 1 MiB per call, and `Process.read_bytes` and `TCP.recv_bytes` take a count of at most 1,048,576 (`src/process.rkt`, `src/network.rkt`). So:
  - the sender writes a fixed 4-byte big-endian length, then the bytes in slices of at most 1 MiB, one send per slice;
  - the receiver reads the 4 bytes and rejects a length above its own limit (at most 64 MiB) before it reads the body, then reads in a loop until it has that many bytes, and only then calls `Term.decode`. Both reads may return fewer bytes than asked: `TCP.recv_bytes` returns what is available, and `Process.read_bytes` returns fewer at EOF. EOF before the end is an error;
  - a small helper module (for example `std/frame`) can hold these two loops once `Bytes` lands; it is not part of this plan. The 4-byte length itself needs no new module: `std/binary` (§23.5) writes it and checks it against a limit.

### 16.8 Dependencies

- **`Bytes` first.** Today binary data is `List[Int]` (`IO.read_bytes`, `String.from_bytes`, `Process.send_bytes`). `Bytes` is in §12.5 "Later" and has no plan yet; it must be planned there, and landed, before this section starts. That plan must also say how the byte builtins take and return `Bytes`, and give a slice and a concat, so the framing loops above are easy to write.
- **Generic structs** (§15.3, roadmap 10c), since the type check substitutes the type arguments of generic instances (16.3).
- **The JSON form of enums** (§15.4, roadmap 10d), for the shared tag and values order. This section spells out its own form (16.4), so it does not need §15.4 to be read; it lands after 10d so both formats agree from the start.
- It starts only when a real program needs it, for example a disk cache or messages between Agentica processes.

### 16.9 Not planned

- **Functions and handles:** a `Fn` may capture handles, and a handle (`Task`, `Table`, `FileHandle`, `Process`, `Socket`) is only valid inside the run that made it.
- **Untyped decode:** it is the `binary_to_term` attack surface; the target type is what keeps decode safe.
- **Erlang distribution** (transparent messages between nodes): Agentica processes talk through pipes or TCP with explicit `Term.encode` and `Term.decode`, so failures stay visible as Results.

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
- **Decode** (`JSON.decode`), for a struct field of type `JsonField[T]`: a missing key gives `Absent`; JSON `null` gives `Null`; any other value is decoded as `T` and gives `Value(...)`. The error rule: `Value` adds no path step, so an error inside the value keeps today's path and text (`address.zip: expected String` under `address: JsonField[Address]`, `tags[0]: expected String` under `tags: JsonField[List[String]]`). Only when the `JsonField` field's own value has the wrong kind does the message add "or null": `age: expected signed 64-bit Int or null`, `address: expected object or null`. This happens at the `JsonField` level only. `fail` in `decode-json` (`src/json-typed.rkt`) escapes through `let/ec`, so an inner failure cannot be caught and rewritten; instead the field level checks the top kind of the value itself (the check `decode` makes for `T` before it goes deeper) and fails with the "or null" text, then decodes the value as `T`. Fields that are not `JsonField` still fail with "required field" when missing. Extra keys are still ignored.
- **Encode** (`JSON.encode`, `JSON.from`): `Absent` leaves the key out, `Null` writes `null`, `Value(x)` writes `x` as today. The other keys keep struct declaration order.
- **No `JsonField[Nil]`.** `Value(nil)` would write `null` and could not be told apart from `Null`, so every JSON builtin rejects `JsonField[Nil]`: it is `CHECK-NOT-ENCODABLE` in a `JSON.encode` or `JSON.from` argument and `CHECK-NOT-DECODABLE` in a `JSON.decode` or `JSON.schema` target. The placement check still runs first (see "Which code wins").
- **Schema** (`JSON.schema`): a `JsonField[T]` field is left out of `required`, and its property schema is `{"anyOf": [<schema of T>, {"type": "null"}]}`. The `schema` function in `src/json-typed.rkt` handles `JsonField` before its `reference` fallback, so no `$defs/JsonField` entry is made. `anyOf` and the `"null"` type work in every draft, and the form is the same when `T` is a `$ref` to a struct. When no field of a struct is required, `required` is left out, because draft-04 needs a non-empty list. This also changes structs with no fields: today they get `"required": []` (`src/json-typed.rkt`), and after 10e they get no `required` key. So `required` is left out for any struct with no required field: empty structs and structs whose fields are all `JsonField`. It is a schema change; say so in the changelog. Programs that read `required` without checking can break. The JSON site page (`site/content/library/json.md`) keeps its `Point` example, which reads `required` with `unwrap!`: `Point` has required fields, so it still works. 10e adds a new site example with a struct whose fields are all `JsonField`, showing that `required` is absent and reading it safely with `JSON.get` and a `case`:

  ```agentica
  struct Patch
    name: JsonField[String]
    age: JsonField[Int]
  end

  def main() -> Void
    schema = JSON.schema(Patch)
    case JSON.get(schema, "required")
      ok(names) -> puts(names)
      error(message) -> puts("no required fields")
    end
  end
  ```

  ```output
  no required fields
  ```

  For `UpdateUser`:

  ```json
  {"type": "object",
   "properties": {"name": {"anyOf": [{"type": "string"}, {"type": "null"}]},
                  "age": {"anyOf": [{"type": "integer",
                                     "minimum": -9223372036854775808,
                                     "maximum": 9223372036854775807},
                                    {"type": "null"}]}}}
  ```

- **Round trip:** for an object that has only the struct's declared keys, with values in the form encode writes, decoding it and encoding the result gives back the same object, up to key order (the encoded text follows declaration order). An absent key stays absent and a `null` stays `null`. Other input does not come back unchanged, as today: extra keys are dropped, and an integer decoded into a `Float` field comes back as `1.0`.
- **`case`:** the three variants need three arms, or a `_` arm. `_` is how a program merges absent and null when its API does not tell them apart.
- **Where it is allowed in JSON.** In the type of a JSON builtin target (`JSON.decode`, `JSON.schema`) or argument (`JSON.encode`, `JSON.from`), `JsonField[T]` is allowed only as the direct type of a struct field. Absent and null are about an object key, and only struct fields are object keys with a fixed name. Everywhere else in that type it is `CHECK-JSON-FIELD-PLACE` (new code):
  - an item of a list (`List[JsonField[Int]]`) or a map value (`Map[String, JsonField[Int]]`): a list has no key to leave out, and a map already shows absence by not having the key;
  - a nested `JsonField[JsonField[T]]`: there is no fourth state;
  - an enum payload, once enums have a JSON form (§15.4);
  - the whole argument of `JSON.encode` or `JSON.from` (`JSON.encode(f)` where `f: JsonField[Int]`).

  A decode or schema target cannot be `JsonField` itself: the checker takes only a type name there (`checker.rkt`, the `json-decode json-schema` rule), and a bare `JsonField` with no type arguments is `CHECK-UNKNOWN-TYPE`, as for any generic name today. `T` itself must be decodable (or encodable) as today, or the call is `CHECK-NOT-DECODABLE` (or `CHECK-NOT-ENCODABLE`). The check walks the type the way `decodable-type?` and `encodable-type?` do now, with one more argument that says whether the type is the direct type of a struct field; it reports the first problem it finds, at the span of the target or argument, and the message says where the `JsonField` sits: the struct and field (`Wrapper.items`), "list item", "map value", "nested JsonField", "encode argument" (the whole argument of `JSON.encode` or `JSON.from`), and, after 10d, "payload of `Enum.Variant`".
- **Not a generic exception for `$defs`.** §15.3 and §15.4 keep generic instances out of decode and schema because `$defs` is keyed by the bare type name. `JsonField[T]` is the one generic instance they accept: it never gets a `$defs` entry, since its schema is the inline `anyOf` above.
- **Generic structs (§15.3, 10c).** A field whose type is `JsonField` after substitution, such as `value` in `Box[JsonField[Int]]`, counts as a direct struct field for `JSON.encode` and `JSON.from`. Decode and schema still reject the generic `Box[...]` with `CHECK-NOT-DECODABLE`. The placement walk runs on the field types after substitution, and its `seen` list is keyed by the full instance type (kind, name and type arguments), not the bare struct name as today's walks in `src/checker.rkt` do. So `Box[T]` with `items: List[T]`, used as `Box[JsonField[Int]]`, has `List[JsonField[Int]]` and is `CHECK-JSON-FIELD-PLACE`, and a `Box[Int]` seen earlier does not hide it.
- **Which code wins.** The placement check runs first, before the decodable and encodable checks, so `List[JsonField[Nil]]` in a decode target is `CHECK-JSON-FIELD-PLACE`, not `CHECK-NOT-DECODABLE`. A `JsonField[Nil]` in a good place (a direct struct field) passes the placement check and is then `CHECK-NOT-DECODABLE` or `CHECK-NOT-ENCODABLE`.
- **Binary serialization.** In `Term.encode` and `Term.decode` (§16), `JsonField[T]` is an ordinary generic enum instance (§16.3), written as the 2-element array `[tag, values]` of §16.4: `Absent` is `["Absent", []]` and `Value(x)` is `["Value", [x]]`. It has no special absent-key meaning there: a struct field that holds `Absent` is still written under its key, and a missing key is an error on decode, as for any field.
- **Outside JSON** `JsonField[T]` is an ordinary enum value: locals, parameters, returns, lists and maps may hold it, and it is printable when `T` is (`JsonField.Value(30)`, `JsonField.Absent`). Like every enum it has no `==`; use `case`.
- **Not `Option`.** `JsonField` is only for JSON shapes. `Option` stays a free name, since many programs declare their own `enum Option[T]`; the open question of a builtin `Option[T]` (roadmap, "Later extensions") is not changed by this.
- **Not in this plan.** `JsonField[T]` is always optional and nullable. Separate "required but nullable" and "optional but not nullable" forms are not covered, for example for strict structured-output schemas that need every property in `required`. `additionalProperties: false` is also absent from `JSON.schema` today, and this plan does not add it.
- **Reserved name.** `JsonField` becomes a reserved type name: a user `struct JsonField`, `enum JsonField` or `import ... as JsonField` is `CHECK-REDEFINED-NAME`. This is a breaking change; say so in the changelog.
- **Builtin enum path.** `JsonField` reuses the builtin-enum path that `JsonValue` adds in §15.2 (10b): the checker's enum table, the evaluator, and `src/modules.rkt` import linking for patterns, constructors and the bare nullary forms `JsonField.Absent` and `JsonField.Null` (which arrive as `type-expression`s). It adds one thing: `JsonField` has a type parameter, so its table entry is generic like a user generic enum. For type references, adding `JsonField` to `reserved-type-names` (`src/checker.rkt`) is what keeps a field type like `age: JsonField[Int]` unchanged when `src/modules.rkt` links an imported module.
- **Evaluator:** the decode field loop and the schema object in `src/json-typed.rkt` handle a field whose declared type is `JsonField`. `json-data` and `encode-json` in `src/evaluator.rkt` dispatch on runtime values, and `struct-fields` holds only field names, so they recognise a `JsonField` enum value by its runtime type: `Absent` leaves the key out, `Null` writes `null`, `Value(x)` writes `x`. Once 10d lands, they match `JsonField` before the generic tagged-enum path, since builtin enums are not user enums. Nothing else changes.
- **Diagnostics:** one new code, `CHECK-JSON-FIELD-PLACE`. A missing variant is `CHECK-NON-EXHAUSTIVE-CASE`; a wrong payload type is `CHECK-TYPE-MISMATCH`.
- **VM:** needs the JSON PR (`docs/vm.md` §12.2 item 7) and its type table. `JsonField` is a builtin entry of the enum table with the fixed variant order `Absent`, `Null`, `Value`, written to the Enums section only when a program uses it, as for `JsonValue`. Typed decode, schema and encode need to know that a struct field is a `JsonField[T]`: the type table gets an entry kind for it that points to `T`, like the List and Map entries. If the JSON PR's type table has no such kind, 10e adds it and bumps the bytecode format version (`docs/vm.md` §4); otherwise the layout does not change and there is no bump. The JSON PR adds no placeholder for it.
- **Planned tests:**
  - decode of the three states (key absent, `null`, a value), in the evaluator test and as a site example;
  - path errors through a nested struct (`address: JsonField[Address]` with a bad `address.zip`, message `address.zip: expected String`) and a bad value type (`age: "x"`, message `age: expected signed 64-bit Int or null`, since the VM differential test compares printed output);
  - encode and `JSON.from`: `Absent` leaves the key out, `Null` writes `null`, `Value` writes the value;
  - schema: the `JsonField` field is not in `required`, its property is the `anyOf` with `{"type": "null"}`, a `$ref` inside `anyOf` for a struct `T`, no `required` key when no field is required, and no `required` key for a struct with no fields; the all-`JsonField` site example above (`Patch`), which reads `required` with `JSON.get` and `case`;
  - round trip: for an object with only the declared keys and values in encode's form, decode then encode gives back the same object up to key order, for absent, null and value;
  - `CHECK-JSON-FIELD-PLACE` for a list item, a map value, `JsonField[JsonField[Int]]` and a top-level `JSON.encode` argument, and for `List[JsonField[Nil]]` in a decode target (the placement check wins over `CHECK-NOT-DECODABLE`); `CHECK-REDEFINED-NAME` for a user type named `JsonField`;
  - `JsonField[Nil]` as a direct struct field: `CHECK-NOT-DECODABLE` in a `JSON.decode` and a `JSON.schema` target, `CHECK-NOT-ENCODABLE` in a `JSON.encode` and a `JSON.from` argument;
  - once 10c lands: `JSON.encode` and `JSON.from` of a `Box[JsonField[Int]]` with `Absent`, `Null` and `Value`, `CHECK-NOT-DECODABLE` for `Box[JsonField[Int]]` in a decode and a schema target, and `CHECK-JSON-FIELD-PLACE` for `Box[T]` with `items: List[T]` used as `Box[JsonField[Int]]`;
  - `JsonField` used in an imported module (a struct field of type `JsonField[...]` in the imported module, field types, patterns, `JsonField.Value(x)`, bare `JsonField.Absent` and `JsonField.Null`), checked and run through an `import`;
  - evaluator against VM (`tests/vm-diff-*-test.rkt`) once the VM has JSON.

## 18. Front-end implementation language

**Today:** the front-end (lexer, parser, linker, checker, lowering, bytecode) is written in Racket; the VM is C. The front-end stays in Racket while the language still changes: Phase 8 and the open JSON work (adapters, optional JSON fields, CBOR; sections 15–17). The reference evaluator is also Racket, until it is removed in roadmap 7i.

**Why not now:**

- Two front-ends would double the work of every language change.
- The Racket evaluator stays until 7i as the parity reference for the VM (`tests/vm-diff-*-test.rkt`); after that, golden-output tests replace it (roadmap 7i).

**The goal is distribution: one binary to download.** Measured on Linux x86_64 with Racket CS 9.3:

- `raco exe --orig-exe` on `src/main.rkt` gives one self-contained ELF file (about 68 MB, about 14 MB as `.tar.xz`). It runs in a clean `debian:trixie-slim` container without Racket. Plain `raco exe` (today's `make exe`) is only a 17 MB starter that needs an installed Racket. `raco distribute` (today's `release.yml`) is 66 MB in 3 files and ships no VM.
- The C VM is 207 KB with libgc linked statically and needs only libc. With TLS (7h) the default build also needs the system `libssl.so.3`/`libcrypto.so.3`; every release artifact, the single file included, builds the VM with `OPENSSL=static` (`docs/vm.md` 10.0), so it needs only glibc's own libraries, and ships OpenSSL's `LICENSE.txt`. Built on trixie it needs `GLIBC_2.38` (`__isoc23_strtol`), so release builds need an older glibc baseline or must avoid the C23 `strtol` variants. musl (Alpine) needs a separate build.
- A proof embedded the VM bytes in the Racket executable and wrote them to `~/.cache/agentica/<hash>/agentica-vm` on the first `--vm` run: one file, +144 KB, and it worked in the clean container. A later step could use `memfd_create` (Linux) to avoid writing to disk and to work with `noexec` home directories. Loading the VM as a shared library through the FFI was judged too risky (two garbage collectors, clashes over `exit` and stdio).
- Startup is about 570–630 ms in every mode (`check`, run, `--vm`); Racket boot dominates.

**Near-term path, without a rewrite:** release one Linux file built with `raco exe --orig-exe`, with the VM embedded, on an older glibc baseline. `compile` plus `agentica-vm` already avoid Racket at run time. What is missing is that `--vm` compiles to a new temporary file on each run (`src/main.rkt`); it should reuse a cached `.agcb` keyed by the source and the compiler version. Agentica itself is `Apache-2.0 WITH LLVM-exception`. The file embeds Racket and the VM, so its archive ships Agentica's `LICENSE` and `NOTICE` next to the file, with a `licenses/` directory for the third-party licenses (Racket's and Chez Scheme's `NOTICE` among them); an `agentica --licenses` command that prints them is an option for later.

**When to look again:** a single file does not need a rewrite. The remaining reasons to change the front-end language are startup time and binary size. Look again once the grammar is stable, and only if those measurements still hurt. The roadmap takes this decision in its order step 11, with the source → result start-up (the 7g runners and the server measurement, 7j) and the typed-Python evaluation round (6c); like the multicore schedulers, a rewrite starts only if those numbers call for it.

**Options then:**

- Preferred: self-host the compiler in Agentica (dogfooding), once the VM is fast enough.
- Alternative to evaluate at that moment: Rust. Its enums and `match` fit the AST and the checker, close to Racket's `match`.
- Less suited: Go, which has no sum types.

No rewrite decision is taken now.

## 19. SIMD in the VM

**Status:** on demand. It starts only if profiling (the server measurement, roadmap 7j, or the cross-language benchmarks, phase 12) shows time spent in the routines below. No language change.

**Targets:** AVX2 first, then AVX-512 on x86-64; NEON on ARM later. AVX-512 can lower the clock speed on some Intel CPUs, so a routine uses it only where it was measured faster than AVX2.

**Candidates:**

1. Strings (`vm/strings.c`, `vm/text.c`): UTF-8 validation, code point counting (`length`), char index to byte offset (`at`, `slice`), search (`index_of`, `contains?`, `split`, `replace`), and ASCII `upcase`/`downcase`.
2. The JSON encoder (`vm/json.c`): scanning a string for quotes, backslashes and control characters before escaping.
3. Comparing and copying: call libc `memcpy`, `memcmp` and `memchr` in place of hand-written byte loops. glibc already picks AVX2 or AVX-512 versions at run time, so this needs no build change and can land at any time.
4. Sorting `List[Int]` and `List[Float]` with an AVX-512 sort (for example Intel's x86-simd-sort, BSD-3-Clause, which fits the dependency policy), only if faster lists (8d) add unboxed Int or Float storage. Today list items are boxed 16-byte values, so a vector sort does not apply.
5. HTTP head parsing: picohttpparser (`vm/http_pico.c`, behind `vm/http_parse.h`, `docs/vm.md` 10.6) has an SSE4.2 path that the baseline build leaves off. Enable it with run-time dispatch like the other routines, only if the server measurement shows time in header parsing.

**Not useful:** instruction dispatch, the builtins that take a callback, the HAMT (it already uses POPCNT), SipHash (kept as it is for its resistance to hash flooding), and the GC.

**Build:**

- The default release build stays at baseline x86-64. A SIMD routine is a function compiled with `__attribute__((target("avx2")))` or `target("avx512bw")`, picked once at start-up with `__builtin_cpu_supports` and kept in the read-only runtime data.
- Opt-in flags for local builds skip the run-time choice: `make vm MARCH=x86-64-v3` (AVX2) or `MARCH=x86-64-v4` (AVX-512).
- Every SIMD routine keeps its scalar version. The C tests and the differential tests run both: a test-only switch forces the scalar path, so each path is checked on the same inputs (non-ASCII text, invalid UTF-8, lengths around the vector width).

## 20. Crypto module

**Status:** on demand: it starts when a real program needs it (signed webhooks, tokens, password storage). It needs `Bytes` (§12.5) and lands only after TLS on the VM (roadmap 7h), since it uses the same OpenSSL 3 library, linked the same way (dynamic by default, `OPENSSL=static` as an option, `docs/vm.md` 10.0). The VM needs only OpenSSL 3.0.0 and calls only symbols of the `OPENSSL_3.0.0` version node (CI checks it with `objdump -T`): newer features such as Argon2id and `OSSL_set_max_threads` (3.2) are found at run time, and when `EVP_KDF_fetch` returns `NULL` the call returns an error `Result` that names the missing feature. If it lands after 7i, it is VM only.

**Sketch** (names are not final):

```text
Crypto.sha256(data: Bytes) -> Bytes          # also sha512; blake2b if needed
Crypto.hmac_sha256(key: Bytes, data: Bytes) -> Bytes
Crypto.equal?(a: Bytes, b: Bytes) -> Bool     # constant time
Crypto.random_bytes(n: Int) -> Result[Bytes]  # OS-backed CSPRNG
Crypto.password_hash(password: String) -> Result[String]
Crypto.password_verify(password: String, hash: String) -> Result[Bool]
Crypto.seal(key: Bytes, plain: Bytes) -> Result[Bytes]   # AEAD
Crypto.open(key: Bytes, sealed: Bytes) -> Result[Bytes]
```

- Hex and Base64 encoding go here only if no other module has them by then.
- `password_hash` uses Argon2id when the OpenSSL in use has it (3.2 or later), else scrypt; the hash string carries its algorithm and parameters, so verify needs no settings. `password_verify` of an Argon2id hash on OpenSSL older than 3.2 returns an error `Result`. `OSSL_set_max_threads` (3.2) is looked up at run time too; without it Argon2 runs single-threaded.
- AEAD is AES-256-GCM or ChaCha20-Poly1305. The nonce rule is fixed by the module: `seal` makes a random nonce for each call and puts it in front of the output, so a user never picks or reuses one. `open` fails with `error(...)` on a wrong key or changed data.
- No low-level primitives: no raw block ciphers, no ECB, no unauthenticated modes.
- Errors are `Result` values. Hashes and HMAC have no effect label; `random_bytes`, `password_hash` and `seal` use the existing `random` label.

## 21. VM layers

**Status:** planned (roadmap 7l), after the tasks PR, next to the review of what the VM inherited from Racket (7k). A prerequisite for the JIT (section 22). No behavior change.

- Split `vm/agc.h` into layer headers: core (values, GC, maps, text), rt (scheduler, loop, I/O) and lib (what builtins may see), so library files include only `lib.h`.
- Move each opcode's semantics out of the `vm/interp.c` switch into helpers (`agc_op_concat`, `agc_op_eq`, ...) that both the interpreter and a JIT call.
- Add metadata flags to the builtin table: `pure`, `may_fail`, `allocates`, `may_yield`.
- Give the callback builtins (`map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`, `Range.each`, `times`, `upto`, `downto`), today special `AGC_NATIVE_*` state machines inside `vm/interp.c`, a protocol that compiled code can use too.

## 22. JIT

**Status:** required, not gated (roadmap 7m). It starts after the VM layers (section 21, roadmap 7l) and the server measurement (7j), so it has numbers to beat. It is independent of 7i and of the multicore decision. No language change.

**Tiers:**

- Tier 1 is the interpreter, with a counter per function and per loop (backward jump).
- Tier 2 is a baseline JIT for hot functions, with no speculation at first, so no deoptimization. It emits native code that calls the opcode helpers (`agc_op_concat`, `agc_op_eq`, ... from section 21) and inlines the Int and Float fast paths, register moves and jumps.
- A later tier, type-specialized code with guards and deoptimization, comes only if profiling asks for it.

**Rules:**

- Compiled code keeps the `STEP` and turn-cost checks at the same safe points as the interpreter (backward jumps and calls), so `--max-steps`, fairness (`docs/vm.md` §10.2.1) and cancellation still work.
- Frames stay interpreter-compatible, so a function can be interpreted or compiled, and a call can go either way.
- Black-box parity (`docs/vm.md` §1) holds: exit code, stdout, program stderr and diagnostic codes do not depend on the tier.

**Code generation** (decided in the JIT PR): copy-and-patch (stencils generated at build time with clang, as CPython 3.13 does) or a small hand-written x86-64 assembler. No LLVM or libgccjit at run time (size, and libgccjit is GPL). x86-64 Linux first, ARM64 next.

**Memory:** W^X: code is mapped RW, written, then `mprotect`ed to RX; never RWX. A code cache with a size cap.

**GC:** Boehm scans native stacks conservatively, so JIT frames need no stack maps. Constants embedded in code must still stay reachable: each code object holds its GC references in a scanned table.

**Tests:** the whole differential (later golden) suite and the latency test run with `--jit=off`, `--jit=on` (normal thresholds) and `--jit=always` (compile everything at its first call) in CI, and in the ASan job too.

**Benchmarks:** numbers before and after in `docs/vm-benchmarks.md`.

## 23. Binary data

**Status:** planned (roadmap phase 13). It comes after TCP and TLS on the VM and before HTTP (roadmap order step 7), and before UDP once UDP is planned. No grammar change: new `Int` and `Float` builtins, and a new `std/binary` module.

Programs that speak a binary format must turn numbers into bytes and back: the 4-byte length in front of a message (§16.7), UDP and other packet headers, file headers. Today a program does it by hand with `/ 256` and `% 256`, and it cannot get the bits of a `Float` at all.

### 23.1 Where each part lives

- The roadmap rule "New library features: `std/` first" applies (`roadmap.md`, after the order table). Packing numbers into bytes is pure computation over types that already exist, so it is `std/binary.agc`, written in Agentica. It runs on both backends with no evaluator or VM work, and the vm-diff fixtures test it.
- Bit operations and the `Float` bit conversions are builtins, under exception 5 of that rule (basic operations on the core types): in Agentica each one is a loop over 64 bits, or an exact scaling by powers of two with special cases for `-0.0`, NaN and subnormals, which is slow and easy to get wrong; in C and Racket each is about one line.
- So there is one module, `std/binary`. A separate `std/bits` would have nothing left to hold, since the bit operations are `Int` builtins.
- Binary data stays `List[Int]`, each item in `0 .. 255`, like `IO.read_bytes`, `File.read_bytes`, `Process.send_bytes` and the other `*_bytes` builtins. The compact `Bytes` type stays deferred (§12.5), and this work does not replace it. When `Bytes` lands, the `std/binary` API moves to `Bytes` in the same change as the `*_bytes` builtins.
- No mutable references are planned. Writers return small new lists that the program joins. If a mutable buffer is ever needed, it would be a handle type (like `HttpWriter`), not references.

### 23.2 `Int` bit builtins

```text
Int.bit_and(a: Int, b: Int) -> Int
Int.bit_or(a: Int, b: Int) -> Int
Int.bit_xor(a: Int, b: Int) -> Int
Int.bit_not(a: Int) -> Int
Int.shift_left(a: Int, count: Int) -> Int
Int.shift_right(a: Int, count: Int) -> Int
Int.shift_right_unsigned(a: Int, count: Int) -> Int
```

- Names: `and`, `or` and `not` are reserved words, so these say `bit_`, like Ruby's `bit_length`; the shifts use whole words, like the rest of the library (`index_of`, `from_int`). They are also methods on `Int`: `flags.bit_and(4)`, `x.shift_left(8)`. They have no effects, so an ignored result is `CHECK-UNUSED-VALUE`. The core has no hex literals, so masks are written in decimal (`255`, `65535`).
- Every function works on the 64-bit two's complement form of its arguments and reads the result back the same way.
- `bit_and`, `bit_or`, `bit_xor` and `bit_not` never fail. `bit_not(a)` is `-1 - a`: `bit_not(0)` is `-1`, and `bit_not` of the smallest Int is the largest.
- `shift_left(a, n)` for `n` in `0 .. 63` is the low 64 bits of `a × 2^n`. Bits that leave the top are dropped, and bit 63 becomes the sign, as in C on unsigned types, Java, Go and Rust: `1.shift_left(63)` is `-9223372036854775808`, `(-1).shift_left(1)` is `-2`, `4611686018427387904.shift_left(1)` is `-9223372036854775808`. It wraps instead of failing because a shift works on bits, not on a number: checksums and random generators (CRC-32, xorshift) depend on the dropped bits. A program that wants the overflow check multiplies: `x * 2` still halts with `RUNTIME-INTEGER-OVERFLOW`.
- `shift_right(a, n)` is arithmetic: copies of the sign bit come in at the top. It is `a / 2^n` rounded down, toward minus infinity (`/` truncates toward zero instead): `(-7).shift_right(1)` is `-4`, `(-1).shift_right(10)` is `-1`.
- `shift_right_unsigned(a, n)` is logical: zeros come in at the top, so it reads `a` as an unsigned 64-bit number: `(-1).shift_right_unsigned(60)` is `15`, and the smallest Int shifted by 63 is `1`. For `n >= 1` the result is never negative; for `n = 0` it is `a`. Hashes and random generators need it, where `shift_right` would copy the sign bit.
- A count of 64 or more shifts every bit out, as in Go: `shift_left` and `shift_right_unsigned` give `0`; `shift_right` gives `0` when `a >= 0` and `-1` when `a < 0`. So `(-1).shift_right_unsigned(64 - n)` is a mask of the low `n` bits for every `n` from 0 to 64.
- A negative count halts with `RUNTIME-INVALID-COUNT` at the count argument, the code that `List.take` and `List.repeat` use for bad counts. A negative count is almost always a bug: Ruby turns it into the other shift and Java keeps only its low 6 bits, and both hide the bug.
- Not included: a population count and a bit test. `x.shift_right(i).bit_and(1) == 1` tests bit `i`; `Int.bit_count` comes when a real program needs it.
- Implementation: C computes on `uint64_t`, so there is no signed overflow and no undefined shift, and checks the count before it shifts. Racket uses `bitwise-and`, `bitwise-ior`, `bitwise-xor`, `bitwise-not` and `arithmetic-shift` with an explicit wrap to 64 bits, and handles counts of 64 or more before `arithmetic-shift`, since a huge count would build a huge bignum.

### 23.3 `Float` bit builtins

```text
Float.to_bits(x: Float) -> Int
Float.from_bits(bits: Int) -> Float
Float.to_bits32(x: Float) -> Int
Float.from_bits32(bits: Int) -> Float
```

- `to_bits` gives the IEEE 754 binary64 bits of `x` as a two's complement Int, so a Float with the sign bit set gives a negative Int. `1.0` gives `4607182418800017408` (`0x3FF0000000000000`), `-0.0` gives `-9223372036854775808`, `+inf.0` gives `9218868437227405312` (`0x7FF0000000000000`), `-inf.0` gives `-4503599627370496` (`0xFFF0000000000000`), and the smallest subnormal gives `1`. Every NaN gives the one quiet NaN `9221120237041090560` (`0x7FF8000000000000`), the value CBOR writes too (§16.4), so both backends agree whatever NaN the host makes. It is also a method: `x.to_bits`.
- `from_bits` takes every Int and reads its 64 bits as a binary64. Subnormals, infinities and `-0.0` come back exactly; any NaN pattern gives NaN. So `Float.to_bits(Float.from_bits(n)) == n` for every `n` except NaN patterns other than `0x7FF8000000000000`.
- `to_bits32` rounds `x` to binary32 and gives its 32 bits as an Int in `0 .. 4294967295` (unsigned, since `Int` has room):
  - one rounding from the full 53-bit significand, to nearest with ties to even, as C's `(float)x`;
  - a magnitude of `2^128 - 2^103` or more becomes infinity with the same sign (exactly `2^128 - 2^103` is a tie, and the even neighbour is infinity), while a value just below rounds to the largest finite f32;
  - small magnitudes round to an f32 subnormal or to zero and keep their sign: `2^-150` is a tie and gives `0`, and `3 × 2^-150` gives `2 × 2^-149`;
  - `-0.0` gives `2147483648` (`0x80000000`), `+inf.0` gives `2139095040` (`0x7F800000`), `-inf.0` gives `4286578688` (`0xFF800000`), and every NaN gives `2143289344` (`0x7FC00000`).
- `from_bits32` reads 32 bits as a binary32 and widens it to a Float, which is always exact: every f32, subnormals included, is a binary64 value. It takes `0 .. 4294967295` only; any other Int halts with `RUNTIME-INVALID-NUMBER` at the argument, as `String.from_code` does (that one with `RUNTIME-INVALID-CHARACTER`). A value read from 4 bytes is always in range. NaN patterns give NaN, so `Float.to_bits32(Float.from_bits32(n)) == n` for every `n` except NaN patterns other than `0x7FC00000`.
- Today, without these builtins: a program gets an infinity only from an overflow (`big * big`, since Float literals have no exponent and `String.to_float` rejects `inf`, `nan` and exponents), and NaN from `inf - inf` or `inf * 0.0`, which do not fail; `x / 0.0`, `0.0 / 0.0` included, is `RUNTIME-DIVISION-BY-ZERO`. Since `-0.0 == 0.0`, it tells the two zeros apart only by text (`x.to_s == "-0.0"`). With `to_bits`, `x.to_bits < 0` tests the sign bit of every value except NaN, whose canonical bits are positive (test NaN with `x != x`).
- Implementation: C copies the bits with `memcpy`, converts with `(float)` and `(double)` (the VM never changes the rounding mode), and checks `isnan` first. Racket uses `real->floating-point-bytes` and `floating-point-bytes->real` with 8 or 4 bytes, with `integer-bytes->integer` and `integer->integer-bytes`, and checks for NaN first. Racket CS 9.3's 4-byte conversion rounds as C does: checked against Python's `struct` on ties at `1.0`, the largest finite f32 and the tie above it, f32 subnormal ties, and overflow.

### 23.4 Where the builtins go

No new opcode and no bytecode format change: the VM imports builtins by name (`docs/vm.md` §4.5).

- `src/builtins.rkt`: eleven catalog rows, next to `Int.times` and `Float.from_int`. The checker reads signatures from the catalog, and methods come from the type of the first parameter (`src/checker.rkt` already maps `Int` and `Float` receivers to their modules), so the checker needs no other change. `agentica help Int.shift_left` reads the same rows.
- `src/evaluator.rkt`: one case each, next to `Float.from_int`.
- `src/lower.rkt`: the names in `vm-builtins`.
- `vm/numbers.c`: rows in `agc_number_builtins`, with `AGC_NATIVE_NONE` and `AGC_COST_NONE`.
- Docs in the same PR: the builtin list and the `Int` row of the methods table in `grammar.md`; the programming skill's `references/builtins.md`, and `references/diagnostics.md` for the new uses of `RUNTIME-INVALID-COUNT` and `RUNTIME-INVALID-NUMBER`; `site/content/library/numbers.md`.

### 23.5 `std/binary`

```agentica
import "std/binary.agc" as Binary

def main() -> Void
  header = Binary.write_u16_be(513).unwrap!
  body = Binary.write_f64_le(1.5)
  data = Binary.concat([header, body])
  puts(data)
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_f64_le(data, 2))
end
```

It prints `[2, 1, 0, 0, 0, 0, 0, 0, 248, 63]`, `ok(513)` and `ok(1.5)`.

```text
Binary.read_u8(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i8(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u16_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u16_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i16_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i16_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u32_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u32_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i32_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i32_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u64_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u64_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i64_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i64_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_f32_be(data: List[Int], offset: Int) -> Result[Float]
Binary.read_f32_le(data: List[Int], offset: Int) -> Result[Float]
Binary.read_f64_be(data: List[Int], offset: Int) -> Result[Float]
Binary.read_f64_le(data: List[Int], offset: Int) -> Result[Float]

Binary.write_u8(value: Int) -> Result[List[Int]]
Binary.write_i8(value: Int) -> Result[List[Int]]
Binary.write_u16_be(value: Int) -> Result[List[Int]]
Binary.write_u16_le(value: Int) -> Result[List[Int]]
Binary.write_i16_be(value: Int) -> Result[List[Int]]
Binary.write_i16_le(value: Int) -> Result[List[Int]]
Binary.write_u32_be(value: Int) -> Result[List[Int]]
Binary.write_u32_le(value: Int) -> Result[List[Int]]
Binary.write_i32_be(value: Int) -> Result[List[Int]]
Binary.write_i32_le(value: Int) -> Result[List[Int]]
Binary.write_u64_be(value: Int) -> Result[List[Int]]
Binary.write_u64_le(value: Int) -> Result[List[Int]]
Binary.write_i64_be(value: Int) -> List[Int]
Binary.write_i64_le(value: Int) -> List[Int]
Binary.write_f32_be(x: Float) -> List[Int]
Binary.write_f32_le(x: Float) -> List[Int]
Binary.write_f64_be(x: Float) -> List[Int]
Binary.write_f64_le(x: Float) -> List[Int]

Binary.concat(parts: List[List[Int]]) -> List[Int]
Binary.frame(payload: List[Int]) -> Result[List[Int]]
Binary.read_frame_length(data: List[Int], offset: Int, max: Int) -> Result[Int]
```

- `_be` is big-endian (most significant byte first, network order) and `_le` is little-endian.
- Ranges: `u8` is `0 .. 255`, `i8` is `-128 .. 127`, `u16` is `0 .. 65535`, `i16` is `-32768 .. 32767`, `u32` is `0 .. 4294967295`, `i32` is `-2147483648 .. 2147483647`, `u64` is `0 .. 9223372036854775807` (as an Int, see below), and `i64` is every Int. Signed types use two's complement.
- **Readers** take a zero-based `offset` into `data` and read the type's bytes from there. They never halt the program: every problem is an `error(...)`.
- **Writers** return a new list with exactly the type's bytes. Writers that can fail (a value outside the type) return a `Result`; `i64`, `f32` and `f64` writers cannot fail and return a plain `List[Int]`, so the types say which is which (a `try` on a plain list is a check error).
- **u64:** `Int` is signed, so a u64 above `2^63 - 1` is not an Int. `read_u64_*` returns an error for it instead of a negative number, and `write_u64_*` rejects negative values. A program that needs all 64 bits (a hash, an ID) uses `read_i64_*` and `write_i64_*`, which read and write the same bytes as two's complement. So every `ok` of an integer reader writes back to the same bytes; a float reader does too, except that a NaN pattern other than the canonical one comes back canonical (§23.3).
- **Floats:** `read_f64_*` is `Float.from_bits` of the `i64`, and `write_f64_*` writes the 8 bytes of `Float.to_bits`. `read_f32_*` is `Float.from_bits32` of the `u32`, and `write_f32_*` writes the 4 bytes of `Float.to_bits32`, so it rounds and never fails. The rules for NaN, `-0.0`, infinities and subnormals are those of §23.3.
- **Joining:** for two or three parts, `List.concat` is fine. `concat(parts)` joins any number of parts in order. It splits `parts` in halves and joins them with `List.concat` recursively, so it costs O(n log k) for n bytes in k parts, and the recursion is only about log2 k deep. Build `parts` with `List.map` (O(k)), for example `values.map do |v| Binary.write_i64_be(v) end`. A loop of `out = List.concat(out, part)` copies the whole output each time, O(n²) (23.6).
- **Framing** (§16.7): `frame(payload)` is the 4-byte big-endian length, then the payload. `read_frame_length(data, offset, max)` reads that length at `offset` and returns an error when it is above `max` (a negative `max` is an error too), so a reader rejects a hostile length before it reads the body. The program then reads that many bytes itself (`TCP.recv_bytes` or `Process.read_bytes` in a loop; both may return fewer bytes than asked). Neither function looks at the payload items: `frame` copies them as they are.
- **Errors**, checked in this order; the first that applies is returned:

  | Case | Message |
  |---|---|
  | `read_frame_length` with `max < 0` | `frame limit -1 is negative` |
  | `offset < 0` or `offset > data.size - n` (no overflow for any offset) | `u32 at offset 10 is outside a list of length 12` |
  | an item that is not in `0 .. 255`, the first one by index | `value 300 at index 2 is not a byte` |
  | `read_u64_*` with the top bit set | `u64 at offset 0 does not fit in Int` |
  | a writer's value outside its type | `value 70000 does not fit in u16` |
  | `frame` with more than `4294967295` items | `payload of 4294967296 bytes does not fit in a u32 length` |
  | `read_frame_length` above `max` | `frame length 70000 is above the limit 65536` |

  The type in a message is the one in the function name (`u8`, `i16`, `f32`, ...; `read_frame_length` reads a `u32`). Messages are lowercase with no final period, like other `Result` messages. The index in `is not a byte` is the item's position in `data`, not in the value: reading at offset 10 with a bad first byte gives `at index 10`. Both backends run the same Agentica code, so the text is the same on both.
- **Implementation**, in Agentica on the 23.2 and 23.3 builtins, with no loop over bytes (and no module state, which Agentica does not have):
  - a reader checks the range with `offset < 0 or offset > data.size - n`; reads the items by index (O(1) on the VM; O(offset) on the evaluator, whose lists are linked); checks them all with one `bit_or` of the items and one range test, and walks them again only on failure, to name the first bad one; and combines them with `shift_left` and `bit_or`, whose wrap gives the right `i64`. Signed types below 64 bits sign-extend with `v.shift_left(64 - w).shift_right(64 - w)` for width `w`.
  - a writer checks the range, then returns a list literal of `value.shift_right(8 * k).bit_and(255)`, which is right for negative values too, since `shift_right` is arithmetic.

### 23.6 Cost

Measured on today's VM (AMD Ryzen 5 3550H, Linux) with prototypes of the readers and writers in today's Agentica, using `/`, `%` and `+` where the real module calls the bit builtins (a builtin method call costs the same steps as a binary operator: one for the node and one per operand):

- A 4-byte read costs about 70 steps and an 8-byte read about 120; a 4-byte write about 35 and an 8-byte write about 45. The 1- and 2-byte forms cost less, and a float adds one builtin call (about 3 steps). In time: about 0.4 µs per write and 0.75 to 1 µs per read.
- Each new builtin is one call: one step plus its arguments, and constant time.
- `concat` costs about 35 steps per part, plus the copies. For 25,000 parts of 4 bytes (100,000 bytes), `Binary.concat` took 0.08 s; `List.concat` in a loop took 5.7 s.
- On the evaluator, reading at an offset also walks the list to that offset. Programs that parse big buffers should run on the VM.
- Faster lists (8d) make `push` (`List.append`) cheap (§12.4), so a loop that pushes each byte onto the output is fine too. §12.4 promises nothing for `List.concat`, so `Binary.concat` stays the way to join parts, with the same API. Writers still return new lists: offset writers into an existing list are not planned (`List.set` copies today, and no mutation is planned, 23.1).
- Taking a payload out of a large buffer with `List.drop` and `List.take` copies the rest of the buffer on the VM. If a real program needs that often, a `List.slice` builtin (exception 5 of the roadmap rule) is the fix; it is not part of this plan.

### 23.7 Tests

Each PR of phase 13 brings its own tests: 13a for the builtins, 13b for `std/binary`.

- **Python vectors**, the independent counterpart. A generator script (Python 3, standard library only: `struct`, and `float.as_integer_ratio` for exact values) writes the vectors, one per line, as decimal Ints or the tokens `inf`, `-inf`, `nan` and `-0` (the first line is a header that the fixture skips), into the `.stdin` sidecar of a fixture in `tests/fixtures/vm/`, so the vm-diff shards run the fixture on both backends. The script, its output and the fixture are checked in together; the script is run by hand when the vectors change, and the header says how the output was made. CI never runs Python for this.
  - **13a**, `bits-vectors.py` writes `bits-vectors.stdin` for `bits-vectors.agc`: each `Int` bit builtin on edge values (0, 1, -1, the smallest and largest Int, alternating bit patterns) and counts (0, 1, 63, 64, 65, the largest Int), computed by Python on unbounded ints masked to 64 bits, except that the expected `shift_left` result for counts of 64 or more is written from the §23.2 rule (`0`), not computed, since CPython cannot shift left by the largest Int; `Float.to_bits` and `Float.to_bits32` of Float inputs, against `struct` (`>d` read back as `>q`, `>f` read back as `>I`); `from_bits` and `from_bits32` of bit patterns, against the expected Float.
  - **13b**, `std-binary-vectors.py` writes `std-binary-vectors.stdin` for `std-binary-vectors.agc`: every reader and writer against the bytes of `struct.pack`, with `>` and `<` and the formats `B b H h I i Q q f d`. Ints: 0, 1, -1, the smallest and largest value of each type, the values just outside it (writer errors), and patterns such as `0x0102030405060708` that show the byte order.
  - Float values in both: `0.0`, `-0.0`, `1.0`, `-1.5`, `0.1`, the largest finite value, the smallest normal, the largest and smallest subnormals, both infinities and NaN (expected: the canonical bits), and for decoding NaN patterns with other payloads and signs. For f32 also rounding: ties to even next to `1.0` (`1 + 2^-24`, `1 + 3 × 2^-24`), the largest finite f32 and the tie above it, values that overflow (Python's `struct` raises `OverflowError` there; the script writes infinity of the same sign, which is what C's cast gives), f32 subnormal ties (`2^-150`, `3 × 2^-150`), and the largest and smallest f32 subnormals.
  - A Float input is written as an Int significand `m` (`|m| < 2^53`) and a power of two `e`, or as `inf`, `-inf`, `nan` or `-0`. The fixture builds `Float.from_int(m)` times `2^e`, with the power of two made by repeated squaring of `2.0` or `0.5`; every step is exact, since every power of two from `2^-1074` to `2^1023` is a Float and the script only writes values that are doubles. It makes infinity from an overflow and NaN from `inf - inf`. So the inputs do not depend on `Float.from_bits`, and a decoded Float is compared with the value built by arithmetic (equal `to_s`, and `x != x` for NaN).
  - Each vectors fixture checks every vector in both directions, prints a line for each mismatch, and then `N vectors ok`.
- **Round trips:**
  - 13a, in `float-bits.agc`: `Float.from_bits(Float.to_bits(x))` has the same `to_s` as `x` for every vector value, and `Float.to_bits32(Float.from_bits32(n))` is `n` for every non-NaN `n`; a NaN pattern other than the canonical one comes back canonical.
  - 13b, in `std-binary.agc`: `read(write(v), 0)` is `ok(v)` for every vector value, every width and both byte orders, and `write(read(b, 0))` gives back `b` for every byte pattern of the vectors. The two exceptions are tested on purpose: `read_u64_*` with the top bit set is an error, and a NaN pattern other than the canonical one comes back canonical. `frame` then `read_frame_length` gives the payload's length; `concat` of 0, 1, 2, 3 and many parts, with empty parts.
- **Errors:** 13a: `int-shift-negative.agc` halts with `RUNTIME-INVALID-COUNT`, and `float-from-bits32-negative.agc` (`-1`) and `float-from-bits32-range.agc` (`4294967296`) halt with `RUNTIME-INVALID-NUMBER`; `tests/evaluator-test.rkt` checks those codes and their spans. 13b, in `std-binary.agc`: offsets `-1`, `size - n + 1`, and the smallest and largest Int; items `-1` and `256`; each writer one past each end of its range; the u64 top bit; a frame length above `max`; a negative `max` (`frame limit -1 is negative`).
- **Fixed expected output:** vm-diff only compares the two backends, so it cannot see a bug that both share, and both run the same `std/binary` code. So the evaluator's exact stdout of each fixture above is checked too (no mismatch lines, `N vectors ok`, and the expected lines of the other fixtures): in `tests/evaluator-test.rkt` for 13a and in `tests/std-binary-test.rkt` for 13b. After the evaluator is removed (7i), these become golden outputs.
- If a vectors fixture is slow under the `--max-steps` sweep, list it in `heavy-fixtures` in `tests/vm-diff-common.rkt`.

### 23.8 Moving a function to C later

Under the roadmap rule, a `std/binary` function moves to a C builtin only when a measurement shows it is hot: a `make bench` program, the server measurement (7j) or the cross-language benchmarks (phase 12) show it among the top costs of a real program. Then its body in `stdlib/binary.agc` becomes one call to a new builtin with the same results and the same error strings (they are program data, `docs/vm.md` §1), so user code and its output do not change. Before 7i the builtin needs its Racket twin too. The new builtin is public (no internal helper builtins, `docs/vm.md` §4.5). It goes in an existing builtin module whose first parameter type fits (for example `List.read_u32_be(data, offset)`), never under a module named like the `std/` module's documented import alias, so the import keeps working. It is documented like any other builtin, and the `std/` function becomes a one-line wrapper. Black-box parity holds; only step counts change. The numbers before and after go in `docs/vm-benchmarks.md`.

### 23.9 `std/queue`

§12.3 used to say that `std/queue` is removed once another `std/` module exists, and `std/binary` is such a module. Its PR does not remove `std/queue`: §12.3 now says that the removal waits until 8c has landed `Queue[T]`, and that it is its own PR with a changelog note.

### 23.10 Not planned

- `Bytes` (§12.5), mutable buffers or references (23.1), and writers into an existing list at an offset.
- Half floats (f16), varints (LEB128), hex and Base64: later, each when a real program needs it (§20 keeps hex and Base64 open).

## 24. Logging and debugging

**Status:** planned (roadmap phase 14). Three parts, each its own small PR, all on the VM only (the evaluator is gone by then, or the part changes only VM code):

- 14a, **VM tracing** (24.4): a developer tool inside `agentica-vm`, not a language feature. It comes right after 7h processes and before TCP and TLS, to make the rest of 7h faster to debug.
- 14b, **stack traces on runtime errors** (24.3): after 7i.
- 14c, **`std/log`** with the `--log-*` flags (24.2): after 7i.

No grammar change. 14c adds three `System` builtins and a `std/` module; 14b changes only what the VM prints for a runtime diagnostic.

### 24.1 Today

Checked on the VM (`racket src/main.rkt --vm`, at `2e6da77`):

- Programs have no logging. `IO.warn(x)` writes `x.to_s` and a newline to stderr: no level, no time, no fields, and no way to turn debug lines off. `IO.inspect` writes to stdout, not stderr. `IO.warn("a\nb")` writes two lines, so one message can break into several lines.
- `IO.warn` on the VM makes two `fwrite` calls on the unbuffered stderr, the text and then `"\n"` (`write_text` in `vm/builtins.c`), so two `write(2)` calls. With one scheduler no other task runs between them, since a builtin is never cut by a task switch; another process that shares the VM's stderr can still write between them (not a `Process.spawn` child, whose stderr the VM forwards through a pipe, `docs/vm.md` §10.4).
- There is no `System.env`: `System.env("HOME")` is `CHECK-UNKNOWN-NAME`.
- A runtime diagnostic has one span and no call stack, in all three formats. A failure inside `pick`, called from `load`, called from `main`, shows only the line in `pick`.
- A tail call (`return f(...)`) replaces the caller's frame (`docs/vm.md` §6.1), so 20,000 nested tail calls run and fail later with the frame of the last call only.
- What a stack trace needs is already there: each frame has its function index and saved `pc` (the next instruction, so the call is at `pc - 1`), each function has its name and one span index per instruction, and the spans table has file, line and column. Linked names look like `@2::push` for a function from an imported file, and blocks are named `block@file.agc:10:15`.
- `error` is a reserved name: a module cannot declare `def error` (`CHECK-REDEFINED-NAME`), so a log module cannot have `Log.error`. A wrong imported name (`Log.error` when the module has no `error`) is `CHECK-IMPORT-NAME` with no "did you mean" help.
- `JSON.encode` of a `Map[String, String]` keeps the map's order and escapes `"`, `\` and control characters; non-ASCII text stays as it is. `JSON.encode` of a `String` gives the quoted, escaped text.
- The VM reads one environment variable at start-up into its runtime config (`AGENTICA_VM_TEST_NO_TURN_COST`), and `vm/` has no mutable global state (`docs/vm.md` §10.2.3). Debugging the scheduler, I/O jobs, the GC, processes or the loader means adding `fprintf` by hand.

### 24.2 `std/log`

```agentica
import "std/log.agc" as Log

def expensive_dump() -> String
  return "..."
end

def main() -> Void
  Log.info("server started")
  Log.info_with("request done", {"path": "/items", "status": "200"})
  Log.debug("not shown at the default level")
  if Log.debug?()
    Log.debug("state: #{expensive_dump()}")
  end
  Log.err("cannot open the cache")
end
```

With `agentica --log-time none app.agc`, stderr gets:

```text
INFO server started
INFO request done path=/items status=200
ERROR cannot open the cache
```

and with `--log-format json --log-time none`:

```text
{"level":"info","msg":"server started"}
{"level":"info","msg":"request done","fields":{"path":"/items","status":"200"}}
{"level":"error","msg":"cannot open the cache"}
```

**API:**

```text
Log.debug(message: String) -> Void
Log.info(message: String) -> Void
Log.warn(message: String) -> Void
Log.err(message: String) -> Void
Log.debug_with(message: String, fields: Map[String, String]) -> Void
Log.info_with(message: String, fields: Map[String, String]) -> Void
Log.warn_with(message: String, fields: Map[String, String]) -> Void
Log.err_with(message: String, fields: Map[String, String]) -> Void
Log.debug?() -> Bool
Log.time_text(ms: Int) -> String
```

- **Levels** are `debug`, `info`, `warn` and `error`, in that order. A line is written when its level is at or above the run's level. The default level is `info`.
- **Names.** `error` is reserved (24.1), so the error functions are `err` and `err_with`; the level is still called `error` in the output and in `--log-level`. User functions have no overloads, so the forms with fields are separate `_with` functions. The 14c PR also adds a "did you mean" help to `CHECK-IMPORT-NAME`, made from the module's exported names, so `Log.error(...)` suggests `Log.err`.
- **Fields** are `Map[String, String]`. A map literal is short (`{"path": p, "status": "#{code}"}`), the text format needs strings anyway, and the map keeps its order, so the output order is the order the program wrote. `Json` was the other option: it keeps numbers as numbers in JSON lines, but every value needs `JSON.from`, and the text format has to turn it back into text. Numbers are strings in JSON lines; tools that need a number convert it.
- **`Log.debug?()`** says whether debug lines are on. Only `debug` has one: it is the level that is off by default and where building the message costs most.
- **`Log.time_text(ms)`** turns milliseconds since the Unix epoch into the text the log uses (`2026-10-12T10:15:02.345Z`). It is exported because programs need it too, and so that tests can check it with fixed inputs.

**How the level and format are set.** Three flags of the run, read through three small builtins:

```text
--log-level debug|info|warn|error|off    (default info)
--log-format text|json                   (default text)
--log-time wall|none                     (default wall)

System.log_level() -> String     # "debug", "info", "warn", "error" or "off"
System.log_format() -> String    # "text" or "json"
System.log_time?() -> Bool       # false under --log-time none
```

- `agentica` takes the flags before the file and passes them to the VM, as it does `--seed`; `agentica-vm` takes them too. A bad value exits 2 (`agentica: --log-level needs debug, info, warn, error or off`), and a flag given twice exits 2, like the other options (`docs/vm.md` §9). `agentica test` passes them to the programs under test, as it does `--seed`. A child started with `Process.spawn` does not get them; the parent passes them in the child's arguments when it wants to.
- The settings are read once at start-up into the runtime, and never change during the run. A builtin that reads them is like `System.args`: it reads the run's command line, so there is no mutable state anywhere, and every task and every module sees the same settings. Each log call costs one builtin call to read the level.
- They are builtins under exception 1 of the roadmap rule "New library features: `std/` first" (they read the run's command line, which a program cannot do itself). They go in `System`, never in a builtin module named `Log`, since `Log` is the documented import alias of `std/log`. Everything else (filtering, the time text, the formats, escaping) is Agentica code in `stdlib/log.agc`.
- **Why flags.** Every other setting of a run is a flag (`--seed`, `--max-steps`, `--allow-run`), and a flag is visible in the command an agent runs and in `agentica --help`. An environment variable would need a `System.env` builtin first, and it leaks into every child program; `System.env` stays a separate item for when a real program needs it. A logger value that the program builds (`Log.new(level, format)`) and passes around was the third option: it needs no builtin, but it adds a parameter to every function that logs and to every task argument, agents forget to pass it, and the level still has to come from somewhere outside the program. A program that wants its own filter (per part of the program) can still wrap `std/log` in its own functions.

**Formats.** Both write one line per call to stderr.

- **Text:** `TIME LEVEL MESSAGE key=value ...`, for example `2026-10-12T10:15:02.345Z INFO request done path=/items status=200`. The time is UTC in ISO 8601 with milliseconds, from `Time.now_ms()`; `Log.time_text` turns the number into a date with integer arithmetic only (days since 1970 to year, month and day), so it is plain `std/` code. The level is in capitals. The message is written as it is, unless it is empty, starts or ends with a space, or contains `=`, `"`, `\` or a control character (DEL included): then it is written in its JSON form (quoted and escaped). So a message with a newline still takes one line, and a message never looks like a field. A field is `key=value`; the key and the value are written as they are unless they are empty or contain a space, `=`, `"`, `\` or a control character, and then in their JSON form. "As it is" is tested with `JSON.encode(s) == "\"#{s}\""` (the encoder escapes `"`, `\`, control characters and DEL) plus checks for empty, spaces and `=`, a few builtin calls per part, so there is no loop over characters in Agentica. Fields come in map order. With these rules every text line can be read back: the message is a JSON string or ends before the first ` key=` (a bare message has no `=`, and a bare key has no space).
- **JSON lines:** one object per line, with `time` (the same text), `level` (lower case), `msg`, and `fields` (an object, left out when there are no fields). The fields are nested, so a field called `level` or `msg` never clashes with the fixed keys. The line is built with `JSON.object` and `JSON.from` and written with `JSON.encode`, so all escaping is the JSON encoder's.
- **`--log-time none`** leaves the time out in both formats. Tests use it, so their expected stderr never changes. It is also useful in production when a supervisor (journald, a container runtime) already adds its own time. A fixed fake clock under a test flag was the other option; it was not chosen because it would also change what `Time.now_ms` returns to the program, and `none` is simpler.

**One line, one write.** `std/log` builds the whole line and calls `IO.warn` once. The 14c PR changes `IO.warn` on the VM to write the text and the newline with one `write(2)` (today two, 24.1). With one scheduler, lines from different tasks already never mix inside a line, since a builtin runs to its end before another task runs. One write also keeps the line whole against other writers to the same descriptor: another process that shares the VM's stderr (POSIX makes a write of up to `PIPE_BUF`, 4096 bytes on Linux, to a pipe atomic; longer lines may still mix with another process's output), and multicore schedulers, if they land, where one `fwrite` on one `FILE` is atomic. It does not cover a `Process.spawn` child's stderr: the VM forwards it in chunks as they arrive, not by line (`src/process.rkt` does the same), so a log line of the parent can still land in the middle of a child's line.

**Cost of a debug line that is off.** Agentica has no lazy arguments, so in `Log.debug("state: #{dump()}")` the message is built before the call, and then `Log.debug` reads the level and returns: about ten steps plus the cost of the message. This is accepted. When the message is costly, the program writes `if Log.debug?() ... end`. A block form (`Log.debug_lazy do "..." end`) was not chosen: a block that captures variables makes a closure on every call, even when debug is off, and it would be a second way to do the same thing. Log calls are normal Agentica code, so they count against `--max-steps`.

**Tests**, with fixed expected output on the VM (exit code, stdout, stderr, diagnostic code):

- Fixtures run with `--log-time none` and compare stderr exactly: each level against each `--log-level`, `off`, both formats, messages and fields that need quoting (space, `=`, `"`, `\`, newline, empty, non-ASCII), no fields, field order, a field named `level`.
- Lines from several tasks (`Task.spawn`, each logging in a loop) are each whole. In text, every stderr line must match, as a whole, `LEVEL SP MESSAGE (SP KEY "=" VALUE)*` (with `--log-time none`), where `LEVEL` is `DEBUG`, `INFO`, `WARN` or `ERROR`, `SP` is one space, `MESSAGE` is a JSON string or one or more characters that are not `=`, `"`, `\` or control characters and do not start or end with a space, and `KEY` and `VALUE` are each a JSON string or one or more characters that are not space, `=`, `"`, `\` or control characters; every JSON string must decode with `string->jsexpr`, and the decoded message, keys and values must equal what the task logged. In json, every line must decode to an object with exactly the keys `level`, `msg` and, when there are fields, `fields`, with the logged values.
- `--log-time wall`: every line starts with a time that matches the format and lies between `Time.now_ms()` read before and after it.
- `Log.time_text` against vectors from a checked-in Python script (standard library `datetime` only, as in §23.7): the epoch, leap days, 2000-02-29, 2100-03-01, the end of a year, a negative time, and large values.
- Bad flag values and repeated flags exit 2.

**Docs in the 14c PR:** `grammar.md` (the `System` builtins and the flags; the advice "logs go to stderr with `IO.warn`" points to `std/log`), the programming skill (a `references/log.md` file and its row in the "When to read a reference" table; the stdio advice in `SKILL.md`), `site/content/library/log.md` with runnable examples (`--log-time none`), and `docs/vm.md` §9 for the flags.

### 24.3 Stack traces on runtime errors

**Always on, in all three formats.** A runtime diagnostic shows the call stack of the task that failed. There is no flag: agents read the default output and would not know to pass one, and the cost is paid only when the run fails. The stack is shown when the failing task has more than one frame, or when the failing task is not `main`; a failure directly in `main` looks as it does today.

Plain format:

```text
nested.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]
index 5 is outside a list of length 3

2 |   return xs[i] + 1
  |             ^
  = stack, innermost first:
    pick at nested.agc:2:13
    load at nested.agc:7:11
    main at nested.agc:14:8
```

`--ai` adds the same lines after `source:`, under `  stack:`. `--json` adds a `stack` array of `{"column":13,"file":"nested.agc","function":"pick","line":2}` objects, innermost first, with keys sorted like the other keys.

- **Each frame** is one line: the function's name and the place it was running, `file:line:column`. The innermost frame is the place of the error (the diagnostic's span start). For a caller frame it is the call it is waiting on: the span of the instruction at its saved `pc - 1`.
- **Names:** the declared name; the linker's `@N::` prefix is cut, and the file shows where the function lives. A block shows as `block`. Native frames (a `List.map` running a block, `docs/vm.md` §4.3) are skipped: the line of the frame below already points at the `xs.map` call.
- **Tail calls:** a frame that a tail call replaced is gone, as in Lua or Scheme. The frame left after one or more tail calls ends with `(after a tail call)` (JSON: `"tail":true`), so a reader knows that callers are missing there. `TAIL_CALL` sets a flag in the frame, and `CALL` clears it.
- **Repeats:** neighbouring frames with the same function and the same place are one line with a count: `walk at tree.agc:9:12 (9998 times)` (JSON: `"repeat":9998`). Deep recursion that ends in `RUNTIME-STACK-OVERFLOW` takes a few lines, not 10,000.
- **Cap:** after repeats are merged, at most 20 lines: the 15 innermost, a line `... 312 frames not shown ...`, and the 5 outermost (JSON: the same frames and a top-level `"stack_omitted":312`). Two functions that call each other a thousand times do not merge, so this is what keeps them short.
- **Tasks:** the stack is the failing task's own, and its last frame is the task's function. A line `task spawned at file:line:column` follows (JSON: `"spawned_at"`): the span of the `Task.spawn` call, kept in the task when it is spawned. The parent's stack at that time is not kept.
- **Which diagnostics:** every `RUNTIME-` diagnostic raised while a task runs, `RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` included (the stack shows where a runaway loop is). Not: `System.exit`, the out-of-memory exit 70 (its handler allocates nothing, `docs/vm.md` §6.3), front-end and `LOWER-` diagnostics, and failures outside any task: the stall check `every task is waiting and nothing can wake them` (`RUNTIME-INTERNAL`, raised by the scheduler between turns, `vm/task.c`) and a failed flush of stdout at the end of the run. Today `vm->task` still points to the last task after its turn ends, so the scheduler clears it when a turn ends (or, if code between turns still needs it, keeps a `running` flag that is set and cleared around each turn), and `agc_fail` copies a stack only while a task is running.
A bigger `--json` example. A task runs `worker`, spawned at `app.agc:30:7`. `worker` calls `walk`, which calls itself 50 times from the same place. Then `walk` calls `ping`, and `ping` and `pong` call each other 400 frames deep (not as tail calls). The last `pong` calls `step`, which tail-calls `leaf`, which fails. So `leaf` has the tail mark, the innermost `pong` shows its call to `step` (line 13), and the other `pong` frames show their call to `ping` (line 15). The VM prints one line; it is shown here across lines. The stack has 20 entries: the 15 innermost, then the 5 outermost, and `stack_omitted` counts the 383 `ping` and `pong` frames between them. A frame object has `column`, `file`, `function` and `line`, plus `repeat` when it stands for more than one frame and `tail` when a tail call removed callers there. `spawned_at` is an object with the same place keys:

```text
{"code":"RUNTIME-DIVISION-BY-ZERO","file":"app.agc","message":"division by zero",
 "range":{"end":{"column":14,"line":2},"start":{"column":13,"line":2}},
 "spawned_at":{"column":7,"file":"app.agc","line":30},
 "stack":[
  {"column":13,"file":"app.agc","function":"leaf","line":2,"tail":true},
  {"column":9,"file":"app.agc","function":"pong","line":13},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"walk","line":20,"repeat":50},
  {"column":3,"file":"app.agc","function":"worker","line":25}],
 "stack_omitted":383}
```

The plain and `--ai` formats show the same 20 lines, with `... 383 frames not shown ...` after the 15th, `(50 times)` and `(after a tail call)` at the end of their lines, and `task spawned at app.agc:30:7` last.

- `grammar.md` §7 says diagnostics never show host exceptions or tracebacks; that stays true, since these frames are Agentica functions.

**Cost.** While the program runs: `TAIL_CALL` stores one flag, and `Task.spawn` stores one span index. Nothing else: frames, names and spans already exist. On failure: `agc_fail` copies the failing task's frames (function, `pc`, tail flag) into the outcome before cleanup runs, O(depth), at most about 10,000; `vm/diag.c` merges, cuts and formats them; and only `vm/main.c` prints (`docs/vm.md` §6.2).

**Tests:** a fixture set with fixed expected stderr in all three formats: nested calls, a function from an imported file, a block run by `List.map`, a failing task (spawn line), a tail call (the flag), deep non-tail recursion to `RUNTIME-STACK-OVERFLOW` (repeats), two functions that call each other deeply (the cap), and a failure in `main` alone (no stack). Expected outputs of other fixtures that end in a runtime diagnostic are regenerated in the same PR, with a reviewed diff. Docs: `grammar.md` §7, `docs/vm.md` §2.5 and §6.1, and the programming skill's `references/diagnostics.md`.

### 24.4 VM tracing

A developer tool for `agentica-vm`, for debugging the scheduler, I/O jobs, processes, TLS, the loader and the GC without adding `fprintf` by hand. It is not part of the language: not in `grammar.md` or the programming skill, only in `docs/vm.md` and the development skill.

**Turning it on:** `AGENTICA_VM_TRACE=sched,io,proc` (a comma list), or `all`. An environment variable, not a flag, because:

- it reaches the VM however it is started (`agentica --vm`, the test harnesses, BDD, a VM started by a program with `Process.spawn`) without adding a flag to each driver's pass-through list;
- it is not a setting of the program, so it does not belong next to `--seed` and `--max-steps`;
- the VM already reads a test variable once at start-up into its config (24.1).

Unset or empty means off. An unknown name writes one line `agc-trace unknown category "x"` and is ignored, so a typo never changes the exit code. A child started with `Process.spawn` inherits the variable (children inherit the environment), so a child VM traces too.

**Where the lines go:** descriptor 2 (stderr) by default. `AGENTICA_VM_TRACE_FILE=path` sends them to a file instead: `vm/main.c` opens it once at start-up with `O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC` (mode 0600) and keeps the descriptor in the `agc_trace` struct. If it cannot be opened, the VM writes one line `agc-trace cannot open PATH` to stderr and traces nothing. A child VM inherits both variables and opens the same file; `O_APPEND` puts each of its lines after the others.

**Line format:** one line per event:

```text
agc-trace +0.012345 sched spawn task=2 parent=1 fn=worker
agc-trace +0.013002 io start job=7 kind=read task=2 timeout_ms=-1
agc-trace +0.013950 io done job=7 us=948 result=ok
```

`agc-trace`, the time since the VM started in seconds with microseconds (`CLOCK_MONOTONIC`), the category, the event, then `key=value` pairs. Numbers are written in decimal. A text value (a path, a function name, a kind) is written as it is, unless it is empty or contains a space, `=`, `"`, `\` or a control character: then it is written in its JSON form, quoted and escaped, the same rule as the fields of `std/log` (24.2). `agc_trace_emit` formats numbers with `vsnprintf`, and text values go through a small escaper into the same buffer; an `agc_string` is passed as its bytes and byte length (`%.*s` when it needs no escaping), since it is not NUL-terminated. Each line is formatted into a 512-byte buffer on the C stack (longer lines are cut and end with `...`) and written with one `write(2)` to the trace descriptor, never through the `FILE *` stderr, so it does not touch the stdio buffer. A failed trace write is ignored: it never ends the run (unlike `agc_write`, which fails with `RUNTIME-INTERNAL`).

One write keeps a trace line whole against other whole-line writers. On stderr that is not enough to keep it apart from everything: the VM forwards a `Process.spawn` child's stderr in chunks, so a trace line can follow a partial line from a child, and then `rg '^agc-trace '` misses it. Use `AGENTICA_VM_TRACE_FILE` when the program runs children, or when the trace must be read by a tool; in a file, every line starts with `agc-trace`.

**Cost when off:** one load, one test and one well-predicted branch per trace point: `AGC_TRACE(rt, AGC_TRACE_SCHED, "spawn task=%" PRIu64 ...)` expands to `if (AGC_TRACE_BUILD && (rt->trace & AGC_TRACE_SCHED)) agc_trace_emit(...)`. Trace points are at events (a spawn, a turn end, a job), never per instruction. `make vm TRACE=0` sets `AGC_TRACE_BUILD` to 0, so the compiler drops every trace point but still type-checks it; the flag goes in the `build/vm/flags` stamp like `SANITIZE`. Release, sanitizer and GC-stress builds keep tracing in, so a user can send a trace. `agentica-vm --version` says `trace off` in a `TRACE=0` build.

**It never changes what the program sees**, except for the added trace lines on stderr (none when they go to a file):

- Trace code reads state and never changes it: no GC allocation (only the stack buffer, numbers and bytes that already exist, such as a function's name), no steps, no turn cost, no change to when tasks switch.
- No mutable globals (`docs/vm.md` §10.2.3): `vm/main.c` reads the variable before loading, into an `agc_trace` struct (category mask and start time), passes it to `agc_load`, and stores it in `agc_runtime`. Each task gets an id from `_Atomic uint64_t next_task_id` in the runtime, with `atomic_fetch_add` at spawn, so it stays safe with N schedulers (`main` is 1). Ids are given whether tracing is on or not, one atomic add per spawn, so a task's id never depends on which categories are on. They are for trace lines only; programs never see them.
- **Signals:** nothing traces from a real signal handler (the out-of-memory and GC abort handlers of `docs/vm.md` §6.3, or any `sigaction` handler); those paths may call only `write(2)` with a fixed text, and they already do. libuv's `uv_signal_t` callbacks run on the loop thread, not in the handler, so they may trace.
- **Thread-pool threads** do not trace: the `work` half of a job has no runtime pointer. The `done` half, on the loop thread, traces the job with the time it spent in the pool (the start time is saved in the job only when `io` is on).
- **Tests run with tracing off:** `AGENTICA_VM_TRACE` and `AGENTICA_VM_TRACE_FILE` are removed in one place for the whole run: `unexport AGENTICA_VM_TRACE AGENTICA_VM_TRACE_FILE` in the Makefile covers `make test` and every other target, and for a direct `raco test`, `tests/vm-diff-common.rkt` and `tests/cli-in-process.rkt` remove both from the environment when they load. After 7i every test helper that runs a program goes through these runners, so it inherits the removal; a developer's exported variable cannot change expected output. Only `tests/vm-trace-test.rkt` sets them: it runs a few fixtures (tasks, files and stdin, processes with a child that writes to stderr, a runtime failure) with `AGENTICA_VM_TRACE=all` and `AGENTICA_VM_TRACE_FILE` in a temporary directory, and checks that exit code, stdout and stderr are byte for byte the same as without tracing, that every line of the trace file matches the format, and that each category it expects appears. The `vm-sanitizers` CI job also builds `make vm TRACE=0`, so the compiled-out form keeps compiling.

**Where the code goes:** `vm/trace.h` (the `agc_trace` struct, the category bits, the `AGC_TRACE` macro) and `vm/trace.c` (`agc_trace_parse` for the variable, `agc_trace_emit` with `vsnprintf` and `write`), under the C rules of the development skill (file order, no static prototypes, `agc_` names). The Makefile adds `vm/trace.c`. `vm/` is already in the `ci.yml` path list.

**First version** (14a, right after 7h processes): the categories `sched`, `io`, `proc`, `tls`, `loader` and `gc`. `tls` is defined in 14a, and the TCP and TLS PR adds its trace points as it lands; later PRs add their own categories in the same way (`net`, `http`). First trace points:

- **`sched`:** task spawn (id, parent, function name), turn end (task, steps used, turn cost, why: yield, park or done), wake (task, by what), the cancel of pending tasks when `main` returns (how many), the stall check, a task failure (code).
- **`io`:** job start (job, kind, task, timeout), job done (job, time in the pool, ok or error), job timeout, handle lock wait and hand-off (handle, task), stdin read (bytes, EOF), each `uv_run` (mode, time blocked), end-of-run close (jobs left, and the `_exit` path).
- **`proc`:** spawn (pid, path, argument count), exit (pid, status or signal), kill and reap on close, EOF on each pipe, stderr bytes passed on; and the signal watchers of the process guard (start, stop, a signal seen in its loop callback, cleanup, raise again).
- **`tls`:** handshake start and end (result, protocol version), the `want read`/`want write` waits, alerts and errors (with the TCP and TLS PR).
- **`loader`:** file size and format version, the size of each table (sources, spans, constants, builtins, functions, structs, types, enums, variants), the reason a file is rejected (the same text as the error), and the load time.
- **`gc`:** at the end of a turn and at the end of the run, when `GC_get_gc_no()` has changed since the last line: the collection count, heap size, free bytes, and bytes allocated since the last collection, all from Boehm's getters. Not a collection callback: `GC_set_on_collection_event` has no user data, so it would need a global. Boehm's own `GC_PRINT_STATS=1` gives more detail. Under `AGC_NO_GC` (ASan builds) this category writes nothing.

### 24.5 Not planned

- Log files, rotation, syslog, sampling, per-module levels, `Json` field values, and log configuration through environment variables.
- Lazy log arguments or a block form (24.2).
- A flag to turn stack traces off, and a stack of the parent task at spawn time.
- VM tracing as a language feature, or trace lines on stdout.
