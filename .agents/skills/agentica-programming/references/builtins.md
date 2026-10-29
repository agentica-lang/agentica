# Builtins

Signatures of the core namespaces. A row written `x.name(...)` is a Ruby name:
write it in method form only (`String.strip(s)` is `CHECK-UNKNOWN-NAME`). Other
rows may be written either way (`String.length(s)` or `s.length`). `agentica
help NAME` prints a signature in method form (`s.strip()`; `--json` adds
`ruby`). A Ruby or other name (`strip`, `value!`) prints the builtin it stands
for (`--json`: `{"alias", "builtins", "hints"}`); one with only a hint (`len`,
`int`) prints it and exits 2, as does an unknown name. Builtin namespaces and
type names are reserved: no declaration, local, parameter, field or import alias
may use them. `ok` and `error` are calls, never declared names.

## Output, input, system

```text
puts(value: T) -> Void                  # value needs to_s; adds a newline
print(value: T) -> Void                 # no newline
gets() -> Result[String]                # = IO.gets
gets!() -> String                       # = IO.gets!; gets!.strip needs no parentheses
IO.puts(value: T) -> Void
IO.print(value: T) -> Void
IO.warn(value: T) -> Void               # stderr, with newline
IO.inspect(value: T) -> T               # prints the debug form, returns the value
IO.gets() -> Result[String]             # ok(line), or error at end of input
IO.gets!() -> String                    # halts at end of input
IO.read() -> String                     # to end of input (not IO.read_all); not for line protocols
IO.eof?() -> Bool                       # peeks one byte; may block; not a readiness poll
IO.flush() -> Void                      # stdout only
System.args() -> List[String]           # the ARGS after the file
System.exit(code: Int) -> Void
Time.now_ms() -> Int                    # wall clock, Unix ms; may jump
Time.monotonic_ms() -> Int              # never goes backward; use for durations
Time.monotonic_ns() -> Int              # nanoseconds; same origin as monotonic_ms
Random.int(min: Int, max: Int) -> Int   # both ends inclusive; min > max halts (RUNTIME-INVALID-RANGE)
Random.float() -> Float                 # 0.0 up to, not including, 1.0
```

- `IO.read_bytes`, `System.env`, `System.os`, `System.pid`: `processes.md`.
- `IO.gets` strips LF, CR or CRLF; a blank line is `ok("")`, not the end.
  `IO.eof?` consumes nothing. Reads have no timeout; step budgets do not
  interrupt blocking input.
- `Random` has one generator per run, seeded from the OS unless `--seed N` is
  given (N in `0 .. 2147483647`); each task's generator is split at spawn. Not
  for secrets: use `SecureRandom` (`binary.md`).

## Int, Float

```text
Int.times(n: Int, f: Fn[Int, Void]) -> Void              # 0 .. n - 1; nothing when n <= 0
Int.upto(from: Int, to: Int, f: Fn[Int, Void]) -> Void   # both ends included; nothing when to < from
Int.downto(from: Int, to: Int, f: Fn[Int, Void]) -> Void # both ends included; nothing when to > from
n.to_f() -> Float                                        # Int
x.to_i() -> Result[Int]                                  # Float; truncates; NaN, infinity, overflow are errors
x.to_i!() -> Int                                         # same, but halts (RUNTIME-INVALID-NUMBER)
```

A negative literal receiver needs parentheses: `(-3).upto(3) do |i| ... end`.
Bit operations: `binary.md`.

## String

```text
String.length(s: String) -> Int                          # Unicode characters
String.bytesize(s: String) -> Int                        # UTF-8 bytes (a C length); no list built
String.empty?(s: String) -> Bool
String.upcase(s: String) -> String
String.downcase(s: String) -> String
s.strip() -> String
String.split(s: String, separator: String) -> List[String]   # keeps empty parts; "" gives characters
parts.join(separator: String) -> String               # List[String]
s.include?(part: String) -> Bool
s.start_with?(prefix: String) -> Bool
s.end_with?(suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String   # bad range halts
String.index_of(s: String, part: String) -> Result[Int]      # first match; error if absent
String.at(s: String, index: Int) -> String               # one character; halts outside
String.reverse(s: String) -> String
c.code() -> Int                                          # code point of one character; other lengths halt
String.compare(a: String, b: String) -> Int              # -1, 0 or 1 in sort order; also a.compare(b)
String.from_code(n: Int) -> String                       # Unicode scalar value; halts otherwise
n.to_s() -> String                                       # Int
x.to_s() -> String                                       # Float
String.from_bytes(data: List[Int]) -> Result[String]     # strict UTF-8; binary.md
String.to_bytes(s: String) -> List[Int]                  # UTF-8 bytes, 0..255
s.to_i() -> Result[Int]                                  # signed decimal; overflow is an error
s.to_f() -> Result[Float]                                # 1.5, 1e+20, +inf.0: reads x.to_s back
s.to_i!() -> Int                                         # halts on bad text (RUNTIME-INVALID-NUMBER)
s.to_f!() -> Float
```

- `"a,,b,".split(",")` is `["a", "", "b", ""]`; `"abc".split("")` is
  `["a", "b", "c"]`.
- `index_of` and `at` count characters, like `length`. Use `code` and
  `from_code` for character arithmetic. Strings cannot be indexed (`s[0]`).
- No regex builtin (`=~`, `matches?`). `s.chars` is `s.split("")`, `s.ord` is
  `s.code`. `s.bytes` gives a `Bytes` (`bytes.md`); `s.to_bytes` still gives a
  `List[Int]`.

## List

```text
List.size(list: List[T]) -> Int
List.empty?(list: List[T]) -> Bool
List.first(list: List[T]) -> T                           # halts when empty (RUNTIME-INDEX-OUT-OF-RANGE), like xs[0]
List.last(list: List[T]) -> T                            # halts when empty
xs.push(value: T) -> List[T]                             # near constant time: n pushes build a list in O(n)
List.set(list: List[T], index: Int, value: T) -> List[T] # 0..length-1, else RUNTIME-INDEX-OUT-OF-RANGE; O(log32 n)
List.repeat(value: T, count: Int) -> List[T]             # count 0..1048576, else RUNTIME-INVALID-COUNT
List.reverse(list: List[T]) -> List[T]
List.concat(a: List[T], b: List[T]) -> List[T]           # O(length of b) when b has at most 32 items, else O(a + b)
List.take(list: List[T], count: Int) -> List[T]          # count above length is fine; negative halts (RUNTIME-INVALID-COUNT)
List.drop(list: List[T], count: Int) -> List[T]          # same count rules as take
List.at(list: List[T], index: Int) -> T                  # halts (RUNTIME-INDEX-OUT-OF-RANGE); O(log32 n)
List.map(list: List[A], f: Fn[A, B]) -> List[B]          # f returns data, not Void
list.select(f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B   # folds left: f(acc, item); empty gives initial
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool         # stops at the first true
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool         # stops at the first false
List.sort(list: List[T]) -> List[T]                      # T is Int, Float or String; stable
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]    # key is Int, Float or String; one call per element
List.find(list: List[A], f: Fn[A, Bool]) -> Result[A]    # ok(first match; stops there) or error("not found")
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

- `map`, `select`, `reduce` are O(n); `sort`, `sort_by` O(n log n); callbacks
  run once per element, left to right, under the caller's execution budget.
- `find` to `max_by` are written in Agentica: O(n), 4 to 28 steps per element
  (`performance.md`); a runtime error in one is reported at your call.
- `reject` is `CHECK-UNKNOWN-METHOD` (use `xs.select do |x| !cond end`). A List
  has no `contains?` or `include?`: use `xs.any? do |x| x == v end` or a Set. A
  range has none of these: `(1..5).to_a.map do ... end`. A block after
  `each_slice` is `CHECK-BLOCK-TARGET`: `xs.each_slice(2).each do |pair| ...
  end`.
- Callback types must match exactly. A callback given as `&name`, a `Fn`
  variable or a block with typed parameters (`do |x: Int|`) types empty lists
  and empty reduce starts. `List.repeat(x, 0)` is an empty list of the inferred
  type.
- Strings sort by code point (`"B"` before `"a"`); Float NaN sorts last; other
  element types are `CHECK-TYPE-MISMATCH`.

## Map

```text
Map.size(map: Map[K, V]) -> Int                          # O(1)
Map.keys(map: Map[K, V]) -> List[K]                      # insertion order; O(n)
Map.values(map: Map[K, V]) -> List[V]                    # same order as keys; O(n)
Map.empty?(map: Map[K, V]) -> Bool
m.key?(key: K) -> Bool
Map.get(map: Map[K, V], key: K) -> Result[V]             # ok(value), or error when the key is missing
Map.get(map: Map[K, V], key: K, default: V) -> V         # default is evaluated eagerly
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]   # returns a new map
Map.delete(map: Map[K, V], key: K) -> Map[K, V]          # absent keys are ignored; O(log n) amortized
Map.each(map: Map[K, V], f: Fn[K, V, Void]) -> Void      # f(key, value) in insertion order
m.select(f: Fn[K, V, Bool]) -> Map[K, V]                 # keeps the entries f accepts, in order
```

- Lookup, `key?` and `put` are effectively constant time (a persistent
  32-way HAMT). `m[key]` on a missing key is `RUNTIME-KEY-NOT-FOUND`.
- `false` and `nil` are present values. Deleting keeps the order of the rest;
  re-inserting puts a key at the end; `put` on an existing key keeps its place.

## Set

```text
Set.new(items: List[T]) -> Set[T]                        # T is Int, String or Bytes; repeats dropped, first keeps its place
Set.add(set: Set[T], value: T) -> Set[T]                 # a member leaves the set unchanged
Set.delete(set: Set[T], value: T) -> Set[T]              # a missing element is ignored; O(log n) amortized
Set.include?(set: Set[T], value: T) -> Bool
Set.size(set: Set[T]) -> Int                             # O(1)
Set.empty?(set: Set[T]) -> Bool
Set.to_a(set: Set[T]) -> List[T]                         # first-insertion order; O(n)
Set.union(a: Set[T], b: Set[T]) -> Set[T]                # a's elements, then b's that a lacks
Set.intersection(a: Set[T], b: Set[T]) -> Set[T]         # in a's order
Set.difference(a: Set[T], b: Set[T]) -> Set[T]           # in a's order
Set.subset?(a: Set[T], b: Set[T]) -> Bool                # every element of a is in b
```

- `seen = seen.add(x)`; a bare `seen.add(x)` is `CHECK-UNUSED-VALUE`. Membership
  and `add` are effectively constant time. Re-adding a deleted element puts it
  at the end. `for x in set` visits in order.
- No index (`s[0]` is `CHECK-NOT-INDEXABLE`). `Test.eq` compares two sets in any
  order. Element and empty-set typing:
  `language-statements-expressions.md`.

## Range

```text
Range.size(r: Range) -> Int                              # halts (RUNTIME-INTEGER-OVERFLOW) when it does not fit in Int
Range.to_a(r: Range) -> List[Int]                        # more than 1048576 values halts (RUNTIME-INVALID-COUNT)
Range.include?(r: Range, value: Int) -> Bool
Range.each(r: Range, f: Fn[Int, Void]) -> Void
Range.first(r: Range) -> Result[Int]                     # error("the range is empty") when empty
Range.last(r: Range) -> Result[Int]                      # last included value: (1...5).last is ok(4)
Range.lazy(r: Range) -> Lazy[Int]                        # (1..n).lazy.select do ... end.first(3) (lazy.md)
```

- An end before the start is an empty range. Ranges bind looser than every other
  operator (`0...n + 1` is `0...(n + 1)`) and do not chain. Method calls need
  parentheses: `(1..5).to_a`, `(0...n).include?(i)`.
- A range prints as `1..5` or `1...5`, has `==` (same start, end and kind) and
  is not JSON-encodable.

## Result

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]                      # needs an expected Result type
r.ok?() -> Bool
r.unwrap!() -> T                                         # halts with RUNTIME-UNWRAP-ERROR on error
r.unwrap_or(default: T) -> T
r.message() -> String                                    # the error message, or "" for success
```

`r.is_err?`, `r.error?`, `r.value!` and `r.ok!` do not exist: write `!r.ok?` and
`r.unwrap!`. Rules for `ok`, `error` and `try`:
`language-blocks-results.md`; Void: `language-program-types.md`.

## Methods and Ruby names

`receiver.name(args)` calls the builtin of the receiver's static type with the
receiver first; the module is the type's name (`List[T]` uses `List`), except
`Json`, which uses `JSON`. `Int` takes `times`, `upto`, `downto` and the bit
functions; `Channel[T]` takes `send`, `recv`, `close`, `closed?`; `ATS[K, V]`
takes every `ATS` function but `new`. Without
parentheses, `receiver.name` on a non-struct value calls a method with no
arguments (`s.length`, `xs.size`, `r.ok?`); on a struct it reads a field, and
structs and enums have no methods. `.call(...)` invokes a function value. An
unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the type's
methods.

Write the Ruby method names: `strip`, `include?`, `start_with?`, `end_with?`,
`to_i`, `to_f`, `to_i!`, `to_f!`, `push`, `select`, `key?`, `join` on a
`List[String]`, `to_s` and `inspect` on any data value, `n.to_f`, `x.to_i`.
`length` and `size` both work on String, List, Map, Set and Range.

Unlike Ruby, `"abc".to_i` is a `Result[Int]` (an error here), not `0`. A
negative literal receiver needs parentheses: `(-5).to_s` (`-5.to_s` is
`-(5.to_s)`).

## to_s and inspect

- Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `Json`, and
  lists, maps, sets, Results, structs and enums built from those. It is the text
  `"#{x}"` gives: a String as it is, a `Json` as its JSON text, else the
  `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`, `Item(name: "a")`,
  `Shape.Box(1, 2)`). Inside a list or Result, `Json` shows as `<Json>`.
- Functions, tasks and handles (sockets, files, processes, HTTP values) have no
  `to_s`: printing or interpolating one is `CHECK-TYPE-MISMATCH`, `.to_s` on one
  is `CHECK-UNKNOWN-METHOD`.
- `x.inspect` is the `IO.inspect` form as a String, for display only. It differs
  from `to_s` for strings, which keep their quotes, and for `Json` (`<Json>`).
  A struct field named `to_s` is read as the field.

## Other rules

- Values never change, so a method never changes its receiver: assign the
  result (`xs = xs.push(4)`, `m = m.put("k", 1)`). A builtin without effects
  whose non-Void result is ignored is `CHECK-UNUSED-VALUE`; `!`-suffixed
  functions and builtins that take a function are exempt.
- A `?` or `!` suffix belongs to a function name, even with a space before `(`.
  `a!=b` is `a != b`. Variables, parameters and fields cannot take those
  suffixes. By convention `?` means Bool and `!` halts on failure.
