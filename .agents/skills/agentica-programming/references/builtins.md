# Builtin functions

`puts(value)` writes any value with `to_s` (see the methods section of `SKILL.md`) and a newline; `print` writes it without one. Strings print as is. `gets` / `gets!` are `IO.gets` / `IO.gets!` and may drop their parentheses: `line = gets!.strip`. They cannot name variables or parameters. The names `puts`, `print`, `gets`, `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`, `Process`, `List`, `Map`, `Result`, `Range`, `IO`, `System`, `Json`, `JSON`, `Fn`, `Task`, `Channel`, `File`, `Dir`, `Path`, `TCP`, `TLS`, and the builtin types in the Types table of `SKILL.md` are reserved. `ok` and `error` cannot be user function, local, parameter, loop-variable, or field declarations; they remain ordinary name tokens for calls.

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
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool
Range.size(r: Range) -> Int                    # halts when the count does not fit in Int
Range.to_a(r: Range) -> List[Int]              # at most 1048576 values
Range.include?(r: Range, value: Int) -> Bool
Range.each(r: Range, f: Fn[Int, Void]) -> Void
Range.first(r: Range) -> Result[Int]           # error for an empty range
Range.last(r: Range) -> Result[Int]            # last included value: (1...5).last is ok(4)
Int.times(n: Int, f: Fn[Int, Void]) -> Void    # 0 .. n - 1; nothing when n <= 0
Int.upto(from: Int, to: Int, f: Fn[Int, Void]) -> Void    # nothing when to < from
Int.downto(from: Int, to: Int, f: Fn[Int, Void]) -> Void  # nothing when to > from

String.length(s: String) -> Int                # counts Unicode characters
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]  # keeps empty parts: "a,,b,".split(",") is ["a", "", "b", ""]
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

puts(value: T) -> Void                         # T has to_s
print(value: T) -> Void                        # no newline
gets() -> Result[String]                       # same as IO.gets
gets!() -> String                              # same as IO.gets!
IO.puts(value: T) -> Void                      # T has to_s
IO.print(value: T) -> Void                     # no newline
IO.warn(value: T) -> Void                      # standard error
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

`Time.now_ms()` reads wall-clock time as milliseconds since the Unix epoch; it can jump when the system clock changes. `Time.monotonic_ms()` counts milliseconds from an arbitrary origin and never goes backward; subtract two readings to measure durations. `Random.int(min, max)` returns a uniform `Int` in `min .. max`, both inclusive, over the whole `Int` range; `min > max` halts with `RUNTIME-INVALID-RANGE` at the call. `Random.float()` returns a uniform `Float` in `0.0` up to, but not including, `1.0`. Each run has its own generator. Without `--seed` it is seeded from operating-system randomness, so runs differ. `agentica --seed N program.agc` (N in `0 .. 2147483647`, otherwise exit 2) repeats the same sequence for the same program and input. `agentica --seed N test` passes the seed to step handlers and to the programs under test. Each task has its own generator, split from its parent at spawn, so a seeded task repeats its own values. The generator is not suitable for secrets. `Time` and `Random` are reserved builtin module names: no declaration or import alias may use them.

- A `?` or `!` suffix belongs to a function name regardless of whitespace before `(`: `String.contains? (a, b)`. `!` followed by `=` is not a suffix (`a!=b` means `a != b`). Variables, parameters, and fields cannot have these suffixes. By convention `?` means Bool and `!` halts on failure.
- Build lists with literals or `List.append`/`List.repeat`; update them with `List.set`. Concatenate lists with `List.concat`. To change a map, use `Map.put`/`Map.delete`; these operations leave the original unchanged.
- Map lookup, `Map.has_key?`, and `Map.put` use the VM's persistent map (a 32-way HAMT) and are effectively constant-time in map size (technically O(log32 n), excluding key hashing/comparison). `Map.size` is O(1); `Map.keys` is O(n). Updates share unchanged storage rather than copying the whole map.
- Reading a missing map key, an index outside `0 .. length - 1`, or a bad `String.slice` range is a runtime error.
- `String.index_of` and `String.at` count Unicode characters, like `String.length`. Use `String.code`/`String.from_code` for character arithmetic, and `Float.from_int`/`Float.to_int` to mix Int and Float; arithmetic never converts implicitly.

## Collections

`List.map` transforms each element; `List.filter` keeps elements whose predicate returns true. Both preserve order and inputs. `List.reduce` folds left, calling `f(accumulator, item)` with the initial value first; an empty list returns the initial value. Callbacks run exactly once per element, left to right, and use the caller's execution budget and error handling. Callback parameter and return types must match exactly; map callbacks must return data, not Void. Callback signatures (`&name`, a `Fn` variable, or a block with annotated parameters such as `do |x: Int|`) infer empty input lists and empty reduce initial values. All three operations cost O(n), excluding callback work. Pass a block, a named function reference (`&name`), or a function-valued variable.

`List.concat` joins lists of the same element type in O(length of the first list). `List.take` returns the first count elements; `List.drop` removes them. Nonnegative counts above length return the whole list or empty list, respectively; negative counts halt with `RUNTIME-INVALID-COUNT` at the count argument. Both cost O(n). `List.at` reads a zero-based index in O(n); negative or out-of-range indexes halt with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument.

`List.sort` sorts in ascending order; its elements must be `Int`, `Float`, or `String`. `List.sort_by` sorts by the key its function returns, and the key must be `Int`, `Float`, or `String`. The key function runs once per element, left to right. Both sorts are stable: equal elements keep their order. Strings compare by Unicode code point, so `"B"` comes before `"a"`. Float NaN goes last. Other element or key types are `CHECK-TYPE-MISMATCH`. Both cost O(n log n), plus the key calls, and preserve the input.

All collection updates preserve their inputs. `List.append`, `List.set`, and `List.reverse` cost O(n); repeated appends cost O(n²). Indexing is still O(n). `List.repeat` costs O(count) and accepts 0..1048576; zero returns an empty list of the inferred element type, and invalid counts halt with `RUNTIME-INVALID-COUNT` at the count argument. `List.set` requires an index in 0..length-1; otherwise it halts with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument. Expected types support empty collections and Result elements; annotate when there is insufficient context.

`Map.get(map, key)` returns `Result[V]`: `ok(value)` if present, `error(message)` if missing. `Map.get(map, key, default)` returns V and eagerly evaluates the default even when the key exists. False and nil are present values. `Map.delete` ignores absent keys, preserves remaining insertion order, and costs O(n); reinsertion adds the key at the end. `Map.values` costs O(n) and follows `Map.keys` order.

## Ranges

`a..b` includes `b`; `a...b` excludes it. Both ends are `Int`, and the value has type `Range` (start, end and kind; no list inside). `for i in 0...n` iterates without building a list, up to the largest `Int` without overflow; a range whose end is before its start is empty, so `for` never counts down: use `a.downto(b) do |i| ... end`. Ranges bind looser than every other operator (`0...n + 1` is `0...(n + 1)`) and do not chain; a method call needs parentheses: `(1..5).to_a`, `(0...n).include?(i)`. `Range` functions are also methods: `r.size`, `r.to_a`, `r.include?(x)`, `r.each do |i| ... end`, `r.first`, `r.last`. `size` halts with `RUNTIME-INTEGER-OVERFLOW` and `to_a` above 1048576 values with `RUNTIME-INVALID-COUNT`, both at the receiver. `first` and `last` return `error("the range is empty")` for an empty range. A range prints as `1..5` or `1...5` and has `==` (same start, end and kind). It is not JSON-encodable.

`n.times do |i| ... end` runs with `0` to `n - 1`; `a.upto(b) do |i| ... end` and `a.downto(b) do |i| ... end` count up or down, both ends included. They return `Void`. A negative literal receiver needs parentheses: `(-3).upto(3) do |i| ... end`.

`agentica help Map.get` and `agentica help ok` show their signatures. Their JSON help contains `overloads`, with one entry per arity. Other builtin JSON help retains the single-signature format.

## Counted input and flushing

- `IO.read_bytes(count)` waits for count bytes or EOF; it returns integers in `0 .. 255`, not decoded text. Short final reads succeed, EOF before any bytes is `ok([])`, and zero returns `ok([])` without consuming input. Count must be `0 .. 1048576` (1 MiB); invalid counts return an error without consuming input. Input-port failures also return an error. Process larger streams in multiple reads.
- `String.from_bytes` validates byte values and decodes UTF-8 strictly. Empty input succeeds with `""`; invalid, overlong, surrogate, and incomplete sequences return errors, never replacement characters. A byte read can split a UTF-8 character; decode only complete sequences. Text and byte reads share the same port, so switch to text reads only at character boundaries.
- `IO.eof?()` peeks without consuming the next byte. It may block until a byte or EOF arrives; it does not wait for a complete UTF-8 character and is not a readiness poll. Reads have no timeout; step budgets do not interrupt blocking I/O.
- `IO.read()` waits for EOF, so use `IO.gets()` for line-delimited live protocols. `IO.flush()` flushes stdout without closing it; it does not flush stderr. On Linux a print is copied into a 64 KiB buffer per stream and written as the reader takes it, so output reaches a pipe or file without `IO.flush()`; a print waits for room when the reader is slow (other tasks keep running), and `IO.flush()` returns once the buffer is in the pipe or file, so it can wait for a slow reader. Stdout and stderr on the same terminal or file keep the order of the calls. The end of the run also waits (within the flush limit) for both buffers. On other systems output calls do not auto-flush. For MCP stdio, put one compact JSON message on each line, flush after each response, and send logs to `IO.warn`.

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
