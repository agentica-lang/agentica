# Builtins

Signatures of the core namespaces. A row written `x.name(...)` is a Ruby name:
write it in method form only (`String.strip(s)` is `CHECK-UNKNOWN-NAME`). Other
rows may be written either way (`String.length(s)` or `s.length`). `agentica
help NAME` prints a signature in method form (`s.strip()`); a Ruby or other name
(`strip`, `value!`) prints the builtin it stands for, and a name with only a
hint (`len`) prints it and exits 2, as does an unknown name. Builtin namespaces
and type names are reserved: no declaration, local, parameter, field or import
alias may use them. A family reserves only its own name: its members are
`Family.Member` and their functions `Family.Member.fn`
(`OpenSSL.Digest.sha256(data)`, `OpenSSL.Random.uuid`); a member it lacks is
`CHECK-UNKNOWN-NAME`, listing the members. `ok`, `error`, `some` and `none` are
calls, never declared names, except as struct fields (`reply.error`).

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
Time.monotonic_ms() -> Int              # never goes backward; may lag up to ~20 ms (Linux, HPET hosts)
Time.monotonic_ns() -> Int              # nanoseconds; same origin as monotonic_ms
Random.int(min: Int, max: Int) -> Int   # both ends inclusive; min > max halts (RUNTIME-INVALID-RANGE)
Random.float() -> Float                 # 0.0 up to, not including, 1.0
Random.seed() -> Int                    # the run's seed (0..2147483647), the same in every task
```

- `IO.read_bytes`, `System.env`, `System.os`, `System.pid`: `processes.md`.
- `IO.gets` strips LF, CR or CRLF; a blank line is `ok("")`, not the end.
  `IO.eof?` consumes nothing. Reads have no timeout; step budgets do not
  interrupt blocking input.
- `Random` is seeded from the OS unless `--seed N` is given; not for secrets:
  use `OpenSSL.Random` (`crypto.md`). Passing the number from `Random.seed`
  back with `--seed` gives the same random numbers.

## Int, Float

```text
Int.times(int: Int, block: Fn[Int, Void]) -> Void        # 0 .. int - 1; nothing when int <= 0
Int.upto(from: Int, to: Int, block: Fn[Int, Void]) -> Void   # both ends included; nothing when to < from
Int.downto(from: Int, to: Int, block: Fn[Int, Void]) -> Void   # both ends included; nothing when to > from
int.to_f() -> Float                                      # Int
float.to_i() -> Result[Int]                              # Float; truncates; NaN, infinity, overflow are errors
float.to_i!() -> Int                                     # same, but halts (RUNTIME-INVALID-NUMBER)
int.abs() -> Int                                         # also float.abs -> Float; the least Int overflows
int.pow(exponent: Int) -> Int                            # no `**`; negative exponent: RUNTIME-INVALID-COUNT
int.gcd(other: Int) -> Int                               # never negative; 0.gcd(0) is 0
int.clamp(min: Int, max: Int) -> Int                     # also on Float; min > max: RUNTIME-INVALID-RANGE
float.floor() -> Int                                     # also ceil, round (halves away from zero); Float only
Math.sqrt(float: Float) -> Float                         # negative float: RUNTIME-INVALID-NUMBER
```

`floor`, `ceil` and `round` halt like `to_i!` on NaN, infinity or a result
outside Int; `round` takes no digits. Bit operations: `binary.md`.

`format(fmt, args...) -> String` is Ruby's `format`, for a width, digits, a
flag or hex: `format("%-8s|%6.2f|%03d|%x", name, price, n, n)`. Conversions
`%d` and `%x` (Int), `%f` (Float, `.precision` 0 to 50, 6 by default), `%s`
(any value with `to_s`) and `%%`; flags `-` and `0`; width 1 to 1000. `fmt` must
be a one-line `"..."` literal (`CHECK-FORMAT-LITERAL`); `%e`, `%X`, `%+d` and
a format of only plain `%s`/`%d` are `CHECK-FORMAT-SPEC` (use `"#{x}"`); an
Int for `%f` is `CHECK-TYPE-MISMATCH` (`n.to_f`).

## String

```text
String.length(string: String) -> Int                     # Unicode characters
String.bytesize(string: String) -> Int                   # UTF-8 bytes (a C length); no list built
String.empty?(string: String) -> Bool
String.upcase(string: String) -> String
String.downcase(string: String) -> String
string.strip() -> String
String.split(string: String, separator: String) -> List[String]   # keeps empty parts; "" gives characters
list.join(separator: String) -> String                # List[String]
string.include?(part: String) -> Bool
string.start_with?(prefix: String) -> Bool
string.end_with?(suffix: String) -> Bool
String.replace(string: String, from: String, to: String) -> String
String.slice(string: String, start: Int, length: Int) -> String   # bad range halts
String.index_of(string: String, part: String) -> Optional[Int]   # first match; none if absent
String.at(string: String, index: Int) -> String          # one character; halts outside
String.reverse(string: String) -> String
s * n -> String                                          # n copies; n < 0 or over 256 MiB halts (RUNTIME-INVALID-COUNT)
string.code() -> Int                                     # code point of one character; other lengths halt
String.compare(string: String, other: String) -> Int              # -1, 0 or 1 in sort order; also a.compare(b)
string.edit_distance(other: String) -> Int               # Levenshtein, in characters
string.edit_distance(other: String, max: Int) -> Int     # max + 1 once past max (fast); max < 0 fails with RUNTIME-INVALID-COUNT
string.jaro_winkler(other: String) -> Float              # 0.0 to 1.0; "" and "" give 1.0
String.from_code(code: Int) -> String                       # Unicode scalar value; halts otherwise
int.to_s() -> String                                     # Int
float.to_s() -> String                                   # Float
String.from_bytes(data: Bytes) -> Result[String]         # strict UTF-8; binary.md
string.encode(encoding: String) -> Result[Bytes]         # b.decode(encoding) back; bytes.md
string.to_i() -> Result[Int]                             # signed decimal; overflow is an error
string.to_f() -> Result[Float]                           # 1.5, 1e+20, +inf.0: reads x.to_s back
string.to_i!() -> Int                                    # halts on bad text (RUNTIME-INVALID-NUMBER)
string.to_f!() -> Float
```

- `index_of` and `at` count characters, like `length`. Use `code` and
  `from_code` for character arithmetic. Strings cannot be indexed (`s[0]`).
- No regex builtin or `=~`: use `std/regex` (`regex.md`). `s.chars` is
  `s.split("")`, `s.ord` is `s.code`. `s.bytes` gives the UTF-8 bytes as a
  `Bytes` (`bytes.md`); `s.bytes.to_a` gives a `List[Int]`.

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
a + b -> List[T]                                         # a new list; O(length of b) when b has at most 32 items, else O(a + b)
List.take(list: List[T], count: Int) -> List[T]          # count above length is fine; negative halts (RUNTIME-INVALID-COUNT)
List.drop(list: List[T], count: Int) -> List[T]          # same count rules as take
List.at(list: List[T], index: Int) -> T                  # halts (RUNTIME-INDEX-OUT-OF-RANGE); O(log32 n)
List.map(list: List[A], block: Fn[A, B]) -> List[B]      # the block returns data, not Void
list.select(block: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, block: Fn[B, A, B]) -> B   # folds left: block(acc, item); empty gives initial
List.each(list: List[A], block: Fn[A, Void]) -> Void
List.any?(list: List[A], block: Fn[A, Bool]) -> Bool     # stops at the first true
List.all?(list: List[A], block: Fn[A, Bool]) -> Bool     # stops at the first false
List.sort(list: List[T]) -> List[T]                      # T is Int, Float or String; stable
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]    # key is Int, Float or String; one call per element
List.find(list: List[A], block: Fn[A, Bool]) -> Result[A]   # ok(first match; stops there) or error("not found")
List.each_with_index(list: List[A], block: Fn[A, Int, Void]) -> Void   # block(item, index), index from 0
List.flat_map(list: List[A], block: Fn[A, List[B]]) -> List[B]
List.partition(list: List[A], block: Fn[A, Bool]) -> List[List[A]]   # [accepted, rejected]
List.take_while(list: List[A], block: Fn[A, Bool]) -> List[A]      # stops calling the block at the first false
List.drop_while(list: List[A], block: Fn[A, Bool]) -> List[A]
List.each_slice(list: List[A], size: Int) -> List[List[A]]         # no block; size < 1 is RUNTIME-INVALID-COUNT
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]     # K is Int, String or Bytes; first-appearance order
List.tally(list: List[K]) -> Map[K, Int]                 # K is Int, String or Bytes; first-appearance order
List.uniq(list: List[K]) -> List[K]                      # K is Int, String or Bytes; keeps the first of each
List.sum(list: List[N]) -> N                             # Int or Float; empty gives 0 or 0.0; Int overflow halts
List.include?(list: List[T], value: T) -> Bool           # any T with ==; also member?; stops at the first match
List.index(list: List[T], value: T) -> Optional[Int]     # first position of an item == value; none when absent
List.find_index(list: List[A], block: Fn[A, Bool]) -> Optional[Int]   # the block form of index (index takes no block)
List.min(list: List[T]) -> Optional[T]                   # T Int, Float or String; none when empty; also max
List.min_by(list: List[A], key: Fn[A, O]) -> Optional[A]   # key Int, Float or String; first wins ties; empty is none
List.max_by(list: List[A], key: Fn[A, O]) -> Optional[A]   # NaN keys never win unless all are NaN
List.lazy(list: List[A]) -> Lazy[A]                      # a recipe; steps run in a terminal (lazy.md)
```

- Callbacks run once per element, left to right, under the caller's execution
  budget. `find` to `max_by` are written in Agentica: O(n), 4 to 28 steps per
  element (`performance.md`); a runtime error in one is reported at your call.
- `reject` is `CHECK-UNKNOWN-METHOD` (use `xs.select do |x| !cond end`). A List
  has `include?` (also `member?`), not `contains?`. A block after `each_slice`
  is `CHECK-BLOCK-TARGET`: `xs.each_slice(2).each do |pair| ... end`.
- Callback types must match exactly. A callback given as `&name`, a `Fn`
  variable or a block with typed parameters (`do |x: Int|`) types empty lists
  and empty reduce starts.
- Strings sort by code point (`"B"` before `"a"`); Float NaN sorts last; other
  element types are `CHECK-TYPE-MISMATCH`.

## Map

```text
Map.size(map: Map[K, V]) -> Int                          # O(1)
Map.keys(map: Map[K, V]) -> List[K]                      # insertion order; O(n)
Map.values(map: Map[K, V]) -> List[V]                    # same order as keys; O(n)
Map.empty?(map: Map[K, V]) -> Bool
m.key?(key: K) -> Bool
Map.get(map: Map[K, V], key: K) -> Optional[V]           # some(value), or none when the key is missing
Map.get(map: Map[K, V], key: K, default: V) -> V         # default is evaluated eagerly
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]   # returns a new map
Map.delete(map: Map[K, V], key: K) -> Map[K, V]          # absent keys are ignored; O(log n) amortized
Map.each(map: Map[K, V], block: Fn[K, V, Void]) -> Void  # block(key, value) in insertion order
m.select(block: Fn[K, V, Bool]) -> Map[K, V]             # keeps the entries the block accepts, in order
```

- Lookup, `key?` and `put` are effectively constant time. `m[key]` on a missing
  key is `RUNTIME-KEY-NOT-FOUND`.
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
Set.union(set: Set[T], other: Set[T]) -> Set[T]          # set's elements, then other's that set lacks
Set.intersection(set: Set[T], other: Set[T]) -> Set[T]   # in set's order
Set.difference(set: Set[T], other: Set[T]) -> Set[T]     # in set's order
Set.subset?(set: Set[T], other: Set[T]) -> Bool          # every element of set is in other
```

- `seen = seen.add(x)`; a bare `seen.add(x)` is `CHECK-UNUSED-VALUE`.
  Re-adding a deleted element puts it at the end. `for x in set` visits in
  order. No index (`s[0]` is `CHECK-NOT-INDEXABLE`).

## Range

```text
Range.size(range: Range) -> Int                          # halts (RUNTIME-INTEGER-OVERFLOW) when it does not fit in Int
Range.to_a(range: Range) -> List[Int]                    # more than 1048576 values halts (RUNTIME-INVALID-COUNT)
Range.include?(range: Range, value: Int) -> Bool
Range.each(range: Range, block: Fn[Int, Void]) -> Void
Range.first(range: Range) -> Result[Int]                 # error("the range is empty") when empty
Range.last(range: Range) -> Result[Int]                  # last included value: (1...5).last is ok(4)
Range.lazy(range: Range) -> Lazy[Int]                    # (1..n).lazy.select { ... }.first(3) (lazy.md)
Range.map(range: Range, block: Fn[Int, B]) -> List[B]    # as (1..5).to_a.map, without the list first
```

- A range has the Enumerable methods of List with Int values: `map`,
  `select`, `flat_map`, `reduce`, `sum`, `min`, `max` (O(1), `Optional[Int]`),
  `min_by`, `max_by`, `find`, `find_index`, `any?`, `all?`, `each_with_index`,
  `each_slice`, `partition`, `group_by`, `take_while`, `drop_while`. No
  `take`, `drop` or `reject`.

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
error(message: String, kind: String, code: Int, details: Map[String, String], cause: Error) -> Result[T]   # named, optional
error(error: Error) -> Result[T]                         # the same Error, as a Result of another type
result.ok?() -> Bool
result.unwrap!() -> T                                    # halts with RUNTIME-UNWRAP-ERROR on error
result.unwrap_or(default: T) -> T
result.message() -> String                               # the error message, or "" for success
```

`r.is_err?`, `r.error?`, `r.value!` and `r.ok!` do not exist: write `!r.ok?` and
`r.unwrap!`. Rules: `language-blocks-results.md`.

## Optional

```text
some(value: T) -> Optional[T]
none -> Optional[T]                                      # needs an expected Optional type
optional.unwrap_or(default: T) -> T
optional.unwrap!() -> T                                  # halts with RUNTIME-UNWRAP-NONE on none
optional.map(block: Fn[T, U]) -> Optional[U]             # with a block: o.map do |x| x + 1 end
optional.some?() -> Bool
optional.none?() -> Bool
optional.to_result(message: String) -> Result[T]         # ok(x), or error(message) for none
```

## Methods and Ruby names

`receiver.name(args)` calls the builtin of the receiver's static type with the
receiver first; the module is the type's name (`List[T]` uses `List`), except
`JSON.Value`, which uses `JSON`. Without parentheses,
`receiver.name` on a non-struct value calls a method with no arguments
(`s.length`, `xs.size`, `r.ok?`); on a struct it reads a field, and structs and
enums have no methods. `.call(...)` invokes a function value, and an `Fn`
field is called by its name (`store.put(a, b)`). An unknown method
is `CHECK-UNKNOWN-METHOD`, with a suggestion or the type's methods.

Write the Ruby method names. `length` and `size` both work on String, List,
Map, Set and Range. Unlike Ruby, `"abc".to_i` is a `Result[Int]` (an error
here), not `0`. A negative literal receiver needs parentheses: `(-5).to_s`.

## to_s and inspect

- Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `JSON.Value`,
  and lists, maps, sets, Results, structs and enums built from those. It is the
  text `"#{x}"` gives: a String as it is, a `JSON.Value` as its JSON text, else
  the `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`, `Item(name: "a")`,
  `Shape.Box(1, 2)`). Inside a list or Result, `JSON.Value` shows as
  `<JSON.Value>`.
- Functions, tasks and handles (sockets, files, processes, HTTP values) have no
  `to_s`: printing or interpolating one is `CHECK-TYPE-MISMATCH`, `.to_s` on one
  is `CHECK-UNKNOWN-METHOD`.
- `x.inspect` is the `IO.inspect` form as a String, for display only. It differs
  from `to_s` for strings, which keep their quotes, and for `JSON.Value`
  (`<JSON.Value>`). A struct field named `to_s` is read as the field.

## Other rules

- A method never changes its receiver: assign the result (`xs = xs.push(4)`,
  `m = m.put("k", 1)`). A builtin without effects whose non-Void result is
  ignored is `CHECK-UNUSED-VALUE`; `!`-suffixed functions and builtins that take
  a function are exempt.
- A `?` or `!` suffix belongs to a function name, even with a space before `(`.
  `a!=b` is `a != b`. Variables, parameters and fields cannot take those
  suffixes. By convention `?` means Bool and `!` halts on failure.
