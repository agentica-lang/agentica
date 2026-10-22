# Lazy

`Lazy[T]` is a pipeline: a source and steps. Building one runs nothing. A
terminal runs it, pulling one item at a time through every step, so no step
builds a whole list. Each terminal runs the source again from the start (a
channel cannot be read twice: a second terminal goes on where the first
stopped). A `Lazy` is a recipe, not a cursor: there is no `next`, `yield`,
`Enumerator.new` or generator (a producer is a task sending into a `Channel`,
`tasks.md`).

Use it for an endless source, the lines of a big file, the values of a channel,
or when only the first results of a long chain are needed. To walk a whole list
use the eager `List` methods.

```text
List.lazy(list: List[A]) -> Lazy[A]
Range.lazy(range: Range) -> Lazy[Int]                         # (1..n).lazy, (0...n).lazy
Lazy.produce(seed: A, f: Fn[A, A]) -> Lazy[A]                 # seed, f(seed), f(f(seed)) ... without end
File.foreach(path: String, buffer_bytes: Int, timeout_ms: Int) -> Lazy[String]   # lines, read as File.each_line
Channel.lazy(channel: Channel[A], timeout_ms: Int) -> Lazy[A]  # ch.lazy(ms): values until closed and drained

# Steps: each gives a new Lazy and runs nothing
Lazy.map(lazy: Lazy[A], f: Fn[A, B]) -> Lazy[B]
lazy.select(f: Fn[A, Bool]) -> Lazy[A]
Lazy.take(lazy: Lazy[A], count: Int) -> Lazy[A]               # count < 0 is RUNTIME-INVALID-COUNT
Lazy.take_while(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.drop(lazy: Lazy[A], count: Int) -> Lazy[A]               # count < 0 is RUNTIME-INVALID-COUNT
Lazy.drop_while(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.flat_map(lazy: Lazy[A], f: Fn[A, List[B]]) -> Lazy[B]
Lazy.with_index(lazy: Lazy[A], f: Fn[A, Int, B]) -> Lazy[B]   # f(item, index), index from 0
Lazy.each_slice(lazy: Lazy[A], size: Int) -> Lazy[List[A]]    # last slice shorter; size < 1 is RUNTIME-INVALID-COUNT
Lazy.each_cons(lazy: Lazy[A], size: Int) -> Lazy[List[A]]     # windows of size neighbours
Lazy.chunk_while(lazy: Lazy[A], f: Fn[A, A, Bool]) -> Lazy[List[A]]   # new group where f(prev, item) is false

# Terminals: always a Result
Lazy.to_a(lazy: Lazy[A]) -> Result[List[A]]
Lazy.first(lazy: Lazy[A], count: Int) -> Result[List[A]]      # take(count) then to_a
Lazy.each(lazy: Lazy[A], f: Fn[A, Result[Void]]) -> Result[Void]   # stops at f's first error and returns it
Lazy.reduce(lazy: Lazy[A], initial: B, f: Fn[B, A, B]) -> Result[B]
Lazy.find(lazy: Lazy[A], f: Fn[A, Bool]) -> Result[A]         # error("not found") when the source ends
Lazy.write_lines(lazy: Lazy[String], path: String, timeout_ms: Int) -> Result[Void]   # each item + LF into a file
```

```ruby
def main() -> Void
  naturals = Lazy.produce(1) do |n| n + 1 end
  odd_squares = naturals.map do |n| n * n end.select do |n| n % 2 == 1 end
  puts(odd_squares.first(3))                                  # ok([1, 9, 25])
  puts((1..7).lazy.each_slice(3).to_a)                        # ok([[1, 2, 3], [4, 5, 6], [7]])
  done = naturals.each do |n|
    if n > 2
      return error("stop")
    end
    puts(n)
    ok()
  end
  puts(done)                                                  # 1, 2, then error("stop")
end
```

- `take`, `take_while`, `first` and `find` stop the source, so an endless source
  ends. `to_a`, `reduce` and `each` on an endless source never end;
  `--max-steps` stops them (`RUNTIME-STEP-LIMIT`).
- Each item pulled costs one step, each callback a step plus its body. Other
  tasks keep running while a terminal runs. Callbacks run on the calling task; a
  `Lazy` can be shared by tasks.
- No `filter_map` (write `select` then `map`) and no tuples (return a struct
  from `with_index` to keep an item and its index).
- A `Lazy` has no `==`, `to_s` or JSON form; inspect prints `<Lazy>`. A `List`
  method on it (`lz.size`) is `CHECK-UNKNOWN-METHOD`: get a list first with `try
  lz.to_a`. A step only `Lazy` has, on a list or range (`xs.each_cons(2)`), is
  `CHECK-UNKNOWN-METHOD`: write `xs.lazy.each_cons(2)`.
- Steps are methods: `lz |> Lazy.map() do ... end` is `CHECK-PIPE-METHOD`.

## try in the blocks

`try` works in every block of a `Lazy` method (a step, `Lazy.produce`, a
terminal), whatever the block gives; the block still ends with a plain value,
not `ok(...)`: `words.lazy.map do |w| try parse(w) * 10 end.to_a` is the first
`parse` error. A failed `try` ends the pipeline: no later item is pulled, a file
of the run is closed, and the terminal returns the error. A block nested in a
`Lazy` block (`xs.map do ... end` inside a step) follows the usual rule: `try`
there is `CHECK-TRY-CONTEXT` unless that block returns a Result.

## Files and channels

- `File.foreach` opens nothing until a terminal starts, and the terminal closes
  the file before it returns, on every path (end, `first`/`find` had enough, an
  error from the block, a failed `try`, a read error). A crash or cancel of the
  task closes it at the task's end. Read errors, a missing file or a timeout
  `<= 0` end the terminal with an error Result; `buffer_bytes` outside
  1024..16777216 is `RUNTIME-INVALID-COUNT` at the argument.
- `File.foreach(...).each do ... end` with no step in between, written as one
  chain, is `CHECK-LAZY-NO-STEP`: write `File.each_line(path, n, ms) do |line|
  ... end`.
- `ch.lazy(timeout_ms)`: each wait for a value obeys the timeout; a timeout ends
  the terminal with `error("channel: timed out")`. Unlike `File.foreach`, a
  negative timeout is `RUNTIME-INVALID-DURATION` (not an error Result), and
  `ch.lazy(0)` is valid (only what is already there).
- A value a terminal took is gone even if a later step dropped it; `take`,
  `first` and `find` take only what they need, `take_while` consumes the first
  value it rejects. A second terminal on a drained, closed channel gives
  `ok([])`, not an error.

## write_lines

- `write_lines(path, timeout_ms)` takes a `Lazy[String]` (a `Lazy[Int]` is
  `CHECK-TYPE-MISMATCH`: `map` to a String first). It creates or truncates the
  file and writes each item and `\n`: `File.foreach(src, 4096, 1000).drop(1).map
  do |line| ... end.write_lines("out.txt", 1000)` is `ok()` or the first error.
- The file opens before the first item is pulled (a failed open reads nothing)
  and is flushed and closed before the terminal returns, on every path. What was
  written before an error stays. A crash or cancel of the task closes it at the
  task's end.
- A timeout `<= 0`, a bad path, a failed open, write or close, and a line over 1
  MiB end the terminal with an error Result. `timeout_ms` bounds the open, each
  64 KiB write and the close.
