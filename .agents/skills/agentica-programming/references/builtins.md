# Builtins

Exact signatures for the core namespaces. `agentica help NAME` prints the
signature of any builtin. Other namespaces have their own file: File, Dir, Path
in `files.md`; Process in `processes.md`; Task and Channel in `tasks.md`; TCP,
TLS, and HTTP in `network.md`; JSON in `json.md`; Test in `testing.md`; BDD in
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
IO.gets() -> Result[String]             # ok(line) or error at end of input
IO.gets!() -> String                    # halts at end of input
IO.read() -> String                     # reads to end of input; use gets for line protocols
IO.read_bytes(count: Int) -> Result[List[Int]]   # count 0..1048576; bytes 0..255
IO.flush() -> Void                      # stdout only
IO.eof?() -> Bool                       # peeks one byte; may block; not a readiness poll
System.args() -> List[String]
System.exit(code: Int) -> Void
System.env(name: String) -> Result[String]   # error if unset or the name is empty, has = or NUL; ok("") if set empty
System.pid() -> Int                     # the process id of this program (VM only)
Time.now_ms() -> Int                    # wall clock, Unix ms; may jump
Time.monotonic_ms() -> Int              # never goes backward; use it for durations
Time.monotonic_ns() -> Int              # same clock in nanoseconds; same origin as monotonic_ms
Random.int(min: Int, max: Int) -> Int   # uniform, both ends inclusive; min > max halts (RUNTIME-INVALID-RANGE)
Random.float() -> Float                 # 0.0 up to, not including, 1.0
```

- `IO.gets` strips LF, CR, or CRLF; a blank line is `ok("")`, not the end.
- `IO.read_bytes` waits for `count` bytes or end of input. A short final read
  succeeds; end of input before any byte, or a zero count, gives `ok([])`.
  Invalid counts return an error without consuming input. Read in several calls
  for larger streams.
- `String.from_bytes` decodes strictly. A byte read can split a UTF-8 character,
  so decode complete sequences only, and switch to text reads only at character
  boundaries.
- `IO.eof?` does not consume a byte and does not wait for a whole UTF-8
  character. Reads have no timeout; step budgets do not interrupt blocking
  input.
- `IO.flush` flushes stdout, not stderr. On Linux, a print is copied into a 64
  KiB buffer per stream and written as the reader takes it, so output reaches a
  pipe without `IO.flush`. Stdout and stderr to the same file keep the order of
  the calls. `IO.flush` returns once the buffer is in the pipe, so it can wait
  for a slow reader. On other systems, output does not auto-flush. For stdio
  protocols, write one compact JSON message per line, flush after each response,
  and send logs to `IO.warn`.
- `System.env` needs no flag. A value that is not UTF-8 is decoded with U+FFFD
  for each bad byte. The home directory is `System.env("HOME")`. There is no
  call that lists the variables. `AGENTICA_CHANNEL` and a `UV_USE_IO_URING` the
  VM set itself are hidden. A child from `Process.spawn` also does not get
  `AGENTICA_VM_METRICS` or `AGENTICA_VM_METRICS_FILE`, but `System.env` shows
  them to you.
- `System.pid` needs no flag. Pass it to a VM you start with `--driver-pid`:
  that VM checks that its parent is this process.
- `FrontEnd.hand_off` and `FrontEnd.std_source` are for the compiler's own front
  end. Do not call them: any other program halts with `RUNTIME-FRONT-END-ONLY`.
- `Time` and `Random` are reserved module names. `Random` has one generator per
  run, seeded from the OS unless `--seed N` is given (`agentica --seed N
  program.agc`, N in `0 .. 2147483647`). Each task has its own generator, split
  at spawn. The generator is not for secrets.

```ruby
def main() -> Void
  data = IO.read_bytes(4)
  if data.ok?
    text = String.from_bytes(data.unwrap!)
    IO.print(text.unwrap_or("invalid UTF-8"))
    IO.flush()
  end
end
```

## Int, Float

```text
Int.times(n: Int, f: Fn[Int, Void]) -> Void              # 0 .. n - 1; nothing when n <= 0
Int.upto(from: Int, to: Int, f: Fn[Int, Void]) -> Void   # nothing when to < from
Int.downto(from: Int, to: Int, f: Fn[Int, Void]) -> Void # nothing when to > from
Float.from_int(n: Int) -> Float
Float.to_int(x: Float) -> Result[Int]                    # truncates; NaN, infinity, overflow are errors
Float.to_int!(x: Float) -> Int                           # same, but halts (RUNTIME-INVALID-NUMBER)
Int.bit_and(a: Int, b: Int) -> Int                       # 64-bit two's complement; never fails
Int.bit_or(a: Int, b: Int) -> Int
Int.bit_xor(a: Int, b: Int) -> Int
Int.bit_not(a: Int) -> Int                               # -1 - a
Int.shift_left(a: Int, count: Int) -> Int                # wraps; 64 or more gives 0
Int.shift_right(a: Int, count: Int) -> Int               # arithmetic, rounds down; 64 or more gives 0 or -1
Int.shift_right_unsigned(a: Int, count: Int) -> Int      # logical; 64 or more gives 0
Float.to_bits(x: Float) -> Int                           # binary64 bits as an Int; every NaN gives 9221120237041090560
Float.from_bits(bits: Int) -> Float                      # any Int; any NaN pattern gives NaN
Float.to_bits32(x: Float) -> Int                         # rounds to binary32; 0..4294967295; every NaN gives 2143289344
Float.from_bits32(bits: Int) -> Float                    # exact; bits outside 0..4294967295 halt (RUNTIME-INVALID-NUMBER)
```

A negative shift count halts with `RUNTIME-INVALID-COUNT` at the count. The core
has no hex literals: write masks in decimal (`255`, `65535`).
`x.shift_right(i).bit_and(1) == 1` tests bit `i`; `x.to_bits < 0` tests the sign
of a Float (not NaN: use `x != x`).

A negative literal receiver needs parentheses: `(-3).upto(3) do |i| ... end`.
Arithmetic never converts Int and Float implicitly.

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
String.compare(a: String, b: String) -> Int              # -1, 0 or 1 in the order of sort (code point); also a.compare(b)
String.from_code(n: Int) -> String                       # Unicode scalar value; halts otherwise
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.from_bytes(data: List[Int]) -> Result[String]     # strict UTF-8
String.to_int(s: String) -> Result[Int]                  # signed decimal; overflow is an error
String.to_float(s: String) -> Result[Float]
String.to_int!(s: String) -> Int                         # halts on bad text (RUNTIME-INVALID-NUMBER)
String.to_float!(s: String) -> Float
```

- `"a,,b,".split(",")` is `["a", "", "b", ""]`; `"abc".split("")` is `["a", "b",
  "c"]`.
- `index_of` and `at` count characters, like `length`. Use `code` and
  `from_code` for character arithmetic. Strings cannot be indexed with `s[0]`.
- `s.trim` is the method form of `String.trim(s)`. `"a".from_int` is not a
  method: only functions whose first parameter has the receiver's type are.

## List

```text
List.size(list: List[T]) -> Int
List.append(list: List[T], value: T) -> List[T]          # near constant time; n appends build a list in O(n)
List.set(list: List[T], index: Int, value: T) -> List[T] # index 0..length-1; else RUNTIME-INDEX-OUT-OF-RANGE; O(log32 n)
List.repeat(value: T, count: Int) -> List[T]             # count 0..1048576; else RUNTIME-INVALID-COUNT
List.reverse(list: List[T]) -> List[T]
List.concat(a: List[T], b: List[T]) -> List[T]           # O(length of b) when b has at most 32 items, else O(length of a + b)
List.take(list: List[T], count: Int) -> List[T]          # counts above length are fine; negative halts (RUNTIME-INVALID-COUNT)
List.drop(list: List[T], count: Int) -> List[T]          # same count rules as take
List.at(list: List[T], index: Int) -> T                  # zero-based; out of range halts (RUNTIME-INDEX-OUT-OF-RANGE); O(log32 n)
List.map(list: List[A], f: Fn[A, B]) -> List[B]          # f returns data, not Void
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B   # folds left: f(acc, item); empty gives initial
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool         # stops at the first true
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool         # stops at the first false
List.sort(list: List[T]) -> List[T]                      # T is Int, Float, or String; stable
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]    # key is Int, Float, or String; one call per element
List.find(list: List[A], f: Fn[A, Bool]) -> Result[A]    # ok(first match) or error("not found"); stops at the match
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
```

- `map`, `filter`, and `reduce` cost O(n); `sort` and `sort_by` cost O(n log n);
  callback work is extra. Each callback runs once per element, left to right,
  under the caller's execution budget.
- `find` ... `max_by` are written in Agentica (the compiler prelude) and cost
  O(n), 4 to 28 steps for each element (`references/performance.md`). A runtime
  error in one is reported at your call. Each has one name: `select`, `collect`,
  `detect`, `inject` and `reject` are `CHECK-UNKNOWN-METHOD` (`filter`, `map`,
  `find`, `reduce`, and `xs.filter do |x| !cond end`), and a `Range` has none of
  them (`(1..5).to_a.map do ... end`). A block after `each_slice` is
  `CHECK-BLOCK-TARGET`: `xs.each_slice(2).each do |pair| ... end`.
- Callback types must match exactly. A callback given as `&name`, a `Fn`
  variable, or a block with typed parameters (`do |x: Int|`) types empty lists
  and empty reduce starts.
- Strings sort by code point, so `"B"` comes before `"a"`. Float NaN sorts last.
  Other element types are `CHECK-TYPE-MISMATCH`.
- Updates return new lists and leave the input unchanged. `List.repeat(x, 0)` is
  an empty list of the inferred type; annotate when the context is not enough.

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
Map.filter(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]   # keeps the entries f accepts, in insertion order
```

- Lookup, `has_key?`, and `put` are effectively constant time (a persistent
  32-way HAMT); updates share unchanged storage. `m[key]` on a missing key is
  `RUNTIME-KEY-NOT-FOUND`.
- `false` and `nil` are present values. Deleting keeps the order of the rest;
  re-inserting puts a key at the end.

## Set

```text
Set.new(items: List[T]) -> Set[T]                        # T is Int or String; repeated items dropped, the first keeps its place
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
  `CHECK-UNUSED-VALUE`. Membership and `add` are effectively constant time (the
  map HAMT). Re-adding a deleted element puts it at the end.
- `Set.new([])` needs an expected type: `seen: Set[Int] = Set.new([])`
  (`CHECK-EMPTY-SET-TYPE`). A `Set[Float]` or `Set[List[Int]]` is
  `CHECK-SET-ELEMENT-TYPE`.
- `for x in set` visits the elements in order. `puts(set)` prints `Set[1, 2]`.
  There is no `==`, no index (`s[0]` is `CHECK-NOT-INDEXABLE`) and no JSON
  encoding; `Test.eq` compares two sets in any order.

## Range

```text
Range.size(r: Range) -> Int                              # halts (RUNTIME-INTEGER-OVERFLOW) when it does not fit in Int
Range.to_a(r: Range) -> List[Int]                        # more than 1048576 values halts (RUNTIME-INVALID-COUNT)
Range.include?(r: Range, value: Int) -> Bool
Range.each(r: Range, f: Fn[Int, Void]) -> Void
Range.first(r: Range) -> Result[Int]                     # error("the range is empty") when empty
Range.last(r: Range) -> Result[Int]                      # last included value: (1...5).last is ok(4)
```

- `a..b` includes `b`; `a...b` excludes it. The value is a `Range` with no list
  inside, so `for i in 0...n` never builds one. An end before the start is an
  empty range.
- Ranges bind looser than every other operator: `0...n + 1` is `0...(n + 1)`.
  They do not chain. Method calls need parentheses: `(1..5).to_a`,
  `(0...n).include?(i)`.
- A range prints as `1..5` or `1...5`, has `==` (same start, end, and kind), and
  is not JSON-encodable.
- `n.times do |i| ... end` runs `0` to `n - 1`; `a.upto(b)` and `a.downto(b)`
  include both ends. They return Void.

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
receiver as its first argument. There is no dynamic dispatch.

- **Receiver type:** `String`
  - **Module:** `String`

- **Receiver type:** `List[T]`
  - **Module:** `List`

- **Receiver type:** `Map[K, V]`
  - **Module:** `Map`

- **Receiver type:** `Set[T]`
  - **Module:** `Set` (`add`, `delete`, `include?`, `size`, `empty?`, `to_a`,
    `union`, `intersection`, `difference`, `subset?`)

- **Receiver type:** `Float`
  - **Module:** `Float`

- **Receiver type:** `Result[T]`
  - **Module:** `Result`

- **Receiver type:** `Json`
  - **Module:** `JSON`

- **Receiver type:** `Range`
  - **Module:** `Range`

- **Receiver type:** `Channel[T]`
  - **Module:** `Channel` (`send`, `recv`, `close`, `closed?`)

- **Receiver type:** `Int`
  - **Module:** `Int` (`times`, `upto`, `downto`, `bit_and`, `bit_or`,
    `bit_xor`, `bit_not`, `shift_left`, `shift_right`, `shift_right_unsigned`)
    and aliases

Without parentheses, `receiver.name` on a non-struct value is a method with no
arguments: `s.length`, `xs.size`, `r.ok?`. On a struct, `.name` reads a field;
structs and enums have no methods. `.call(...)` invokes a function value. An
unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the list of that
type's methods.

Ruby aliases:

- **Receiver:** `String`
  - **Alias:** `size`
  - **Same as:** `String.length`

- **Receiver:** `String`
  - **Alias:** `to_i`, `to_i!`
  - **Same as:** `String.to_int` (Result), `String.to_int!`

- **Receiver:** `String`
  - **Alias:** `to_f`, `to_f!`
  - **Same as:** `String.to_float` (Result), `String.to_float!`

- **Receiver:** `String`
  - **Alias:** `strip`
  - **Same as:** `String.trim`

- **Receiver:** `String`
  - **Alias:** `include?`, `start_with?`, `end_with?`
  - **Same as:** `String.contains?`, `String.starts_with?`, `String.ends_with?`

- **Receiver:** `String`
  - **Alias:** `to_s`
  - **Same as:** the same string

- **Receiver:** `List`
  - **Alias:** `length`
  - **Same as:** `List.size`

- **Receiver:** `List`
  - **Alias:** `push`
  - **Same as:** `List.append`

- **Receiver:** `List[String]`
  - **Alias:** `join`
  - **Same as:** `String.join`

- **Receiver:** `Int`
  - **Alias:** `to_s`, `to_f`
  - **Same as:** `String.from_int`, `Float.from_int`

- **Receiver:** `Float`
  - **Alias:** `to_s`
  - **Same as:** `String.from_float`

- **Receiver:** `Float`
  - **Alias:** `to_i`, `to_i!`
  - **Same as:** `Float.to_int` (Result), `Float.to_int!`

- **Receiver:** any data value
  - **Alias:** `to_s`
  - **Same as:** the text `"#{x}"` gives

- **Receiver:** any data value
  - **Alias:** `inspect`
  - **Same as:** the text `IO.inspect(x)` prints

Unlike Ruby, `"abc".to_i` is a `Result[Int]` (an error here), not `0`. A
negative literal receiver needs parentheses: `(-5).to_s`, since `-5.to_s` is
`-(5.to_s)`.

## to_s and inspect

- Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `Json`, and
  lists, maps, sets, Results, structs, and enums built from those. `x.to_s` is
  the text `"#{x}"` gives: a String as it is, a `Json` as its JSON text,
  anything else in its `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`,
  `Item(name: "a")`, `Shape.Box(1, 2)`). Inside a list or Result, `Json` shows
  as `<Json>`, so `puts(JSON.parse(s))` prints `ok(<Json>)`.
- Functions, tasks, and resource handles (sockets, files, processes, HTTP
  values) have no `to_s`. Printing or interpolating one is
  `CHECK-TYPE-MISMATCH`; `.to_s` on one is `CHECK-UNKNOWN-METHOD`.
- `nil.to_s` is `"nil"`; `puts([1, 2])` writes `[1, 2]`. A struct field named
  `to_s` is read as the field.
- `x.inspect` is the `IO.inspect` form as a String. It differs from `to_s` for
  strings, which keep their quotes (`"a".inspect` is the quoted text), and for
  `Json`, which gives `<Json>`. The debug form is for display, not guaranteed to
  be valid source.

## Other rules

- Values never change, so a method never changes its receiver. A builtin without
  effects whose non-Void result is ignored is `CHECK-UNUSED-VALUE`. `!`-suffixed
  functions and builtins that take a function are exempt.
- A `?` or `!` suffix belongs to a function name, even with a space before `(`.
  `a!=b` is `a != b`. Variables, parameters, and fields cannot take those
  suffixes. By convention `?` means Bool and `!` halts on failure.
- Build lists with literals, `List.append`, `List.repeat`, and `List.concat`;
  change one element with `List.set`. Change maps with `Map.put` and
  `Map.delete`, and sets with `Set.add` and `Set.delete`. These leave the
  original unchanged.
