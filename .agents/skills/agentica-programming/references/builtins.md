# Builtins

Exact signatures for the core namespaces. `agentica help NAME` prints a
signature but does not resolve Ruby aliases (`String.to_i`); see "Methods on
builtin types". Other namespaces: File, Dir, Path in `files.md`; Process,
`System.env`, `System.os`, `System.pid` and stdio in `processes.md`; Task and
Channel in `tasks.md`; TCP, TLS, HTTP in `network.md`; JSON in `json.md`; bit
operations, `Crypto` and `std/binary` in `binary.md`; `Profile` in
`performance.md`; `Std.source` in `modules.md`; Test in `testing.md`; BDD in
`bdd.md`.

Builtin namespaces and type names are reserved: no declaration, local,
parameter, field, or import alias may use them. `ok` and `error` are calls,
never declared names.

## Output, input, system

```text
puts(value: T) -> Void                  # value needs to_s; adds a newline
print(value: T) -> Void                 # no newline
gets() -> Result[String]                # = IO.gets
gets!() -> String                       # = IO.gets!; may drop parentheses: gets!.strip
IO.puts(value: T) -> Void
IO.print(value: T) -> Void
IO.warn(value: T) -> Void               # stderr, with newline
IO.inspect(value: T) -> T               # prints the debug form, returns the value
IO.gets() -> Result[String]             # ok(line), or error at end of input
IO.gets!() -> String                    # halts at end of input
IO.read() -> String                     # to end of input; not for line protocols
IO.eof?() -> Bool                       # peeks one byte; may block; not a readiness poll
IO.flush() -> Void                      # stdout only; processes.md
System.args() -> List[String]
System.exit(code: Int) -> Void
System.env(name: String) -> Result[String]   # error if unset; processes.md
Time.now_ms() -> Int                    # wall clock, Unix ms; may jump
Time.monotonic_ms() -> Int              # never goes backward; use for durations
Time.monotonic_ns() -> Int              # same clock in nanoseconds
Random.int(min: Int, max: Int) -> Int   # uniform, both ends inclusive; min > max halts (RUNTIME-INVALID-RANGE)
Random.float() -> Float                 # 0.0 up to, not including, 1.0
```

- `IO.gets` strips LF, CR, or CRLF; a blank line is `ok("")`, not the end.
- `IO.eof?` consumes nothing and does not wait for a whole UTF-8 character.
  Reads have no timeout; step budgets do not interrupt blocking input.
- `Time` and `Random` are reserved module names. `Random` has one generator per
  run, seeded from the OS unless `--seed N` is given (`agentica --seed N
  program.agc`, N in `0 .. 2147483647`). Each task's generator is split at
  spawn. It is not for secrets.

## Int, Float

```text
Int.times(n: Int, f: Fn[Int, Void]) -> Void              # 0 .. n - 1; nothing when n <= 0
Int.upto(from: Int, to: Int, f: Fn[Int, Void]) -> Void   # both ends included
Int.downto(from: Int, to: Int, f: Fn[Int, Void]) -> Void # both ends included
Float.from_int(n: Int) -> Float
Float.to_int(x: Float) -> Result[Int]                    # truncates; NaN, infinity, overflow are errors
Float.to_int!(x: Float) -> Int                           # same, but halts (RUNTIME-INVALID-NUMBER)
```

A negative literal receiver needs parentheses: `(-3).upto(3) do |i| ... end`.

## String

```text
String.length(s: String) -> Int                          # Unicode characters
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]   # keeps empty parts; "" gives characters
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String   # bad range halts
String.index_of(s: String, part: String) -> Result[Int]      # first match; error if absent
String.at(s: String, index: Int) -> String               # one character; halts outside
String.reverse(s: String) -> String
String.code(c: String) -> Int                            # code point of one character; other lengths halt
String.compare(a: String, b: String) -> Int              # -1, 0 or 1 in sort order; also a.compare(b)
String.from_code(n: Int) -> String                       # Unicode scalar value; halts otherwise
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.from_bytes(data: List[Int]) -> Result[String]     # strict UTF-8; binary.md
String.to_bytes(s: String) -> List[Int]                  # UTF-8 bytes, 0..255; inverse of from_bytes
String.to_int(s: String) -> Result[Int]                  # signed decimal; overflow is an error
String.to_float(s: String) -> Result[Float]
String.to_int!(s: String) -> Int                         # halts on bad text (RUNTIME-INVALID-NUMBER)
String.to_float!(s: String) -> Float
```

- `"a,,b,".split(",")` is `["a", "", "b", ""]`; `"abc".split("")` is
  `["a", "b", "c"]`.
- `index_of` and `at` count characters, like `length`. Use `code` and
  `from_code` for character arithmetic. Strings cannot be indexed with `s[0]`.
- `s.trim` is the method form of `String.trim(s)`. `"a".from_int` is not a
  method: only functions whose first parameter has the receiver's type are.

## List

```text
List.size(list: List[T]) -> Int
List.append(list: List[T], value: T) -> List[T]          # near constant time
List.set(list: List[T], index: Int, value: T) -> List[T] # 0..length-1, else RUNTIME-INDEX-OUT-OF-RANGE; O(log32 n)
List.repeat(value: T, count: Int) -> List[T]             # count 0..1048576, else RUNTIME-INVALID-COUNT
List.reverse(list: List[T]) -> List[T]
List.concat(a: List[T], b: List[T]) -> List[T]           # O(length of b) when b has at most 32 items, else O(length of a + b)
List.take(list: List[T], count: Int) -> List[T]          # count above length is fine; negative halts
List.drop(list: List[T], count: Int) -> List[T]          # same count rules as take
List.at(list: List[T], index: Int) -> T                  # zero-based; halts (RUNTIME-INDEX-OUT-OF-RANGE); O(log32 n)
List.map(list: List[A], f: Fn[A, B]) -> List[B]          # f returns data, not Void
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B   # folds left: f(acc, item); empty gives initial
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool         # stops at the first true
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool         # stops at the first false
List.sort(list: List[T]) -> List[T]                      # T is Int, Float or String; stable
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]    # key is Int, Float or String; one call per element
List.find(list: List[A], f: Fn[A, Bool]) -> Result[A]   # ok(first match) or error("not found")
List.each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void   # f(item, index), index from 0
List.flat_map(list: List[A], f: Fn[A, List[B]]) -> List[B]
List.partition(list: List[A], f: Fn[A, Bool]) -> List[List[A]]     # [accepted, rejected]
List.take_while(list: List[A], f: Fn[A, Bool]) -> List[A]          # stops calling f at the first false
List.drop_while(list: List[A], f: Fn[A, Bool]) -> List[A]
List.each_slice(list: List[A], size: Int) -> List[List[A]]         # no block; size < 1 is RUNTIME-INVALID-COUNT
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]     # K is Int or String; first-appearance order
List.tally(list: List[K]) -> Map[K, Int]                 # K is Int or String; first-appearance order
List.uniq(list: List[K]) -> List[K]                      # K is Int or String; keeps the first of each
List.sum(list: List[N]) -> N                             # Int or Float; empty gives 0 or 0.0; Int overflow halts
List.min_by(list: List[A], key: Fn[A, O]) -> Result[A]   # key Int, Float or String; first wins ties; empty is an error
List.max_by(list: List[A], key: Fn[A, O]) -> Result[A]   # NaN keys never win unless all are NaN
List.lazy(list: List[A]) -> Lazy[A]                      # a recipe; steps run in a terminal (lazy.md)
```

- `map`, `filter`, and `reduce` cost O(n); `sort` and `sort_by` O(n log n);
  callback work is extra. Each callback runs once per element, left to right,
  under the caller's execution budget.
- `find` to `max_by` are written in Agentica (the compiler prelude): O(n),
  4 to 28 steps per element (`performance.md`). A runtime error in one is
  reported at your call. Each has one name: `select`, `collect`, `detect`,
  `inject` and `reject` are `CHECK-UNKNOWN-METHOD` (use `filter`, `map`, `find`,
  `reduce`, or `xs.filter do |x| !cond end`). A range has none of them:
  `(1..5).to_a.map do ... end`. A block after `each_slice` is
  `CHECK-BLOCK-TARGET`: write `xs.each_slice(2).each do |pair| ... end`.
- Callback types must match exactly. A callback given as `&name`, a `Fn`
  variable, or a block with typed parameters (`do |x: Int|`) types empty lists
  and empty reduce starts.
- Strings sort by code point, so `"B"` comes before `"a"`. Float NaN sorts
  last. Other element types are `CHECK-TYPE-MISMATCH`.
- `List.repeat(x, 0)` is an empty list of the inferred type; annotate when the
  context is not enough.

## Map

```text
Map.size(map: Map[K, V]) -> Int                          # O(1)
Map.keys(map: Map[K, V]) -> List[K]                      # insertion order; O(n)
Map.values(map: Map[K, V]) -> List[V]                    # same order as keys; O(n)
Map.has_key?(map: Map[K, V], key: K) -> Bool
Map.get(map: Map[K, V], key: K) -> Result[V]             # ok(value), or error when the key is missing
Map.get(map: Map[K, V], key: K, default: V) -> V         # default is evaluated eagerly
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]   # returns a new map
Map.delete(map: Map[K, V], key: K) -> Map[K, V]          # absent keys are ignored; O(n)
Map.each(map: Map[K, V], f: Fn[K, V, Void]) -> Void      # f(key, value) in insertion order
Map.filter(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]   # keeps the entries f accepts
```

- Lookup, `has_key?`, and `put` are effectively constant time (a persistent
  32-way HAMT); updates share unchanged storage. `m[key]` on a missing key is
  `RUNTIME-KEY-NOT-FOUND`.
- `false` and `nil` are present values. Deleting keeps the order of the rest;
  re-inserting puts a key at the end.

## Set

```text
Set.new(items: List[T]) -> Set[T]                        # T is Int or String; repeats dropped, first keeps its place
Set.add(set: Set[T], value: T) -> Set[T]                 # a member leaves the set unchanged
Set.delete(set: Set[T], value: T) -> Set[T]              # a missing element is ignored; O(n)
Set.include?(set: Set[T], value: T) -> Bool
Set.size(set: Set[T]) -> Int                             # O(1)
Set.empty?(set: Set[T]) -> Bool
Set.to_a(set: Set[T]) -> List[T]                         # first-insertion order; O(n)
Set.union(a: Set[T], b: Set[T]) -> Set[T]                # a's elements, then b's that a lacks
Set.intersection(a: Set[T], b: Set[T]) -> Set[T]         # in a's order
Set.difference(a: Set[T], b: Set[T]) -> Set[T]           # in a's order
Set.subset?(a: Set[T], b: Set[T]) -> Bool                # every element of a is in b
```

- Sets are immutable like maps: `seen = seen.add(x)`; a bare `seen.add(x)` is
  `CHECK-UNUSED-VALUE`. Re-adding a deleted element puts it at the end.
- `Set.new([])` needs an expected type: `seen: Set[Int] = Set.new([])`
  (`CHECK-EMPTY-SET-TYPE`). A `Set[Float]` or `Set[List[Int]]` is
  `CHECK-SET-ELEMENT-TYPE`.
- `for x in set` visits the elements in order. `puts(set)` prints
  `Set[1, 2]`. There is no `==`, no index (`s[0]` is `CHECK-NOT-INDEXABLE`)
  and no JSON encoding; `Test.eq` compares two sets in any order.

## Range

```text
Range.size(r: Range) -> Int                              # halts (RUNTIME-INTEGER-OVERFLOW) when it does not fit in Int
Range.to_a(r: Range) -> List[Int]                        # more than 1048576 values halts (RUNTIME-INVALID-COUNT)
Range.include?(r: Range, value: Int) -> Bool
Range.each(r: Range, f: Fn[Int, Void]) -> Void
Range.first(r: Range) -> Result[Int]                     # error("the range is empty") when empty
Range.last(r: Range) -> Result[Int]                      # last included value: (1...5).last is ok(4)
Range.lazy(r: Range) -> Lazy[Int]                        # (1..n).lazy.filter do ... end.first(3) (lazy.md)
```

- An end before the start is an empty range. Ranges bind looser than every
  other operator (`0...n + 1` is `0...(n + 1)`) and do not chain. Method calls
  need parentheses: `(1..5).to_a`, `(0...n).include?(i)`.
- A range prints as `1..5` or `1...5`, has `==` (same start, end, and kind),
  and is not JSON-encodable.

## Result

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]                      # needs an expected Result type
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T                        # halts with RUNTIME-UNWRAP-ERROR on error
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String                   # the error message, or "" for success
```

The rules for `ok`, `error`, `try`, and Void are in `language.md`.

## Methods on builtin types

`receiver.name(args)` calls the builtin of the receiver's static type, with the
receiver as its first argument; there is no dynamic dispatch. The module is the
type's name (`List[T]` uses `List`), except `Json`, which uses `JSON`. `Int`
takes `times`, `upto`, `downto` and the bit functions; `Channel[T]` takes
`send`, `recv`, `close` and `closed?`.

Without parentheses, `receiver.name` on a non-struct value is a method with no
arguments (`s.length`, `xs.size`, `r.ok?`). On a struct it reads a field;
structs and enums have no methods. `.call(...)` invokes a function value. An
unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the list of that
type's methods.

Ruby aliases, each the same call as its target:

- `String`: `size` (`length`); `to_i`, `to_i!` (`to_int`, `to_int!`);
  `to_f`, `to_f!` (`to_float`, `to_float!`); `strip` (`trim`);
  `include?`, `start_with?`, `end_with?` (`contains?`, `starts_with?`,
  `ends_with?`); `to_s` (the same string).
- `List`: `length` (`size`); `push` (`append`); `join` on `List[String]`
  (`String.join`).
- `Int`: `to_s` (`String.from_int`); `to_f` (`Float.from_int`).
- `Float`: `to_s` (`String.from_float`); `to_i`, `to_i!` (`Float.to_int`,
  `Float.to_int!`).
- Any data value: `to_s` (the text `"#{x}"` gives); `inspect` (the text
  `IO.inspect(x)` prints).

Unlike Ruby, `"abc".to_i` is a `Result[Int]` (an error here), not `0`. A
negative literal receiver needs parentheses: `(-5).to_s`, since `-5.to_s` is
`-(5.to_s)`.

## to_s and inspect

- Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `Json`, and
  lists, maps, sets, Results, structs and enums built from those. `x.to_s` is
  the text `"#{x}"` gives: a String as it is, a `Json` as its JSON text, else
  its `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`, `Item(name: "a")`,
  `Shape.Box(1, 2)`). Inside a list or Result, `Json` shows as `<Json>`, so
  `puts(JSON.parse(s))` prints `ok(<Json>)`.
- Functions, tasks, and resource handles (sockets, files, processes, HTTP
  values) have no `to_s`: printing or interpolating one is
  `CHECK-TYPE-MISMATCH`, and `.to_s` on one is `CHECK-UNKNOWN-METHOD`.
- `nil.to_s` is `"nil"`; `puts([1, 2])` writes `[1, 2]`. A struct field named
  `to_s` is read as the field.
- `x.inspect` is the `IO.inspect` form as a String. It differs from `to_s` for
  strings, which keep their quotes (`"a".inspect` is the quoted text), and for
  `Json`, which gives `<Json>`. The debug form is for display, not guaranteed
  to be valid source.

## Other rules

- Values never change, so a method never changes its receiver. A builtin
  without effects whose non-Void result is ignored is `CHECK-UNUSED-VALUE`.
  `!`-suffixed functions and builtins that take a function are exempt.
- A `?` or `!` suffix belongs to a function name, even with a space before
  `(`. `a!=b` is `a != b`. Variables, parameters, and fields cannot take those
  suffixes. By convention `?` means Bool and `!` halts on failure.
