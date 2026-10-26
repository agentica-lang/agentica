---
title: Lazy
weight: 6
description: Lazy pipelines over lists, ranges, endless sources, files and channels, run one item at a time by a terminal, with try in the blocks and a terminal that writes a file.
---

A `Lazy[T]` is a recipe: a source and the steps after it. Building one does no work. A terminal (`to_a`, `first`, `each`, `reduce`, `find`, `write_lines`, `write_bytes`) runs it, and pulls one item at a time from the source through every step, so no step builds a list of all the items. A step returns a new `Lazy`; the old one is unchanged, and each terminal runs the source again from the start (a channel, which cannot be read twice, goes on where the last terminal stopped).

Use a `Lazy` for an endless source, for the lines of a big file or the values of a channel, or when only the first few results of a long chain are needed. For a list you will walk whole, the eager [List](/library/data-structures/list/) methods are the one form.

```agentica
def main() -> Void
  squares = Lazy.produce(1) do |n| n + 1 end.map do |n| n * n end
  puts(squares.select do |n| n % 2 == 1 end.first(3))
  puts((1..10).lazy.each_slice(4).to_a)
end
```

```output
ok([1, 9, 25])
ok([[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
```

Every terminal gives a `Result`. `take`, `take_while`, `first` and `find` stop the source when they have enough, so an endless source ends; `to_a`, `reduce` and `each` on an endless source never end, and `--max-steps` stops them with `RUNTIME-STEP-LIMIT`. Each item pulled costs one step, and each callback a step plus its body, as in `Range.each`. A terminal can be switched out between items, so other tasks keep running; a terminal over a file or a channel parks while it waits, and a cancel reaches it there.

A `Lazy` has no `==`, no `to_s` and no JSON form; `IO.inspect` prints `<Lazy>`. There is no `next`: a `Lazy` is a recipe, not a cursor. A `List` method on a `Lazy`, such as `lz.size`, is `CHECK-UNKNOWN-METHOD` with a help that shows `to_a`; a step only `Lazy` has, such as `xs.each_cons(2)` on a list, shows `.lazy`.

## Sources

```text
List.lazy(list: List[A]) -> Lazy[A]
Range.lazy(range: Range) -> Lazy[Int]
Lazy.produce(seed: A, f: Fn[A, A]) -> Lazy[A]
File.foreach(path: String, buffer_bytes: Int, timeout_ms: Int) -> Lazy[String]
File.chunks(path: String, size: Int = 65536, timeout_ms: Int = 30000) -> Lazy[List[Int]]
Channel.lazy(channel: Channel[A], timeout_ms: Int) -> Lazy[A]
```

`Lazy.produce` gives `seed`, then `f(seed)`, then `f(f(seed))`, without end. It does not call its block for an item that no step needs.

```agentica
def main() -> Void
  puts([3, 1, 2].lazy.to_a)
  puts((1...4).lazy.to_a)
  puts(Lazy.produce("a") do |s| s + "a" end.first(3))
end
```

```output
ok([3, 1, 2])
ok([1, 2, 3])
ok(["a", "aa", "aaa"])
```

### File.foreach

The lines of a file, read as [`File.each_line`](/library/io-and-system/files/#fileeach_line) reads them: a block of `buffer_bytes` (1024 to 16777216, also the longest line) at a time, and `timeout_ms` for each read. Building the `Lazy` opens nothing. The file opens when a terminal starts and is closed before the terminal returns, whatever ended it: the end of the file, a `take` or `find` that had enough, an error from the block, a failed `try`. A crash or cancel of the task closes it when the task ends. After a read timeout the handle is released at once, and the OS descriptor closes when the read that timed out ends.

A read error (invalid UTF-8, a line over the buffer), a missing file or a bad timeout ends the terminal with that error. `File.foreach(...).each do ... end` with no step in between, written as one chain, is `CHECK-LAZY-NO-STEP`: write `File.each_line` for that. A buffer outside 1024..16777216 is `RUNTIME-INVALID-COUNT` at the argument.

```agentica {mode="check"}
def main() -> Void
  head = File.foreach("server.log", 4096, 1000).first(10)
  errors = File.foreach("server.log", 4096, 1000).select do |line| line.include?("ERROR") end.each do |line|
    puts(line)
    ok()
  end
  puts(head.ok? and errors.ok?)
end
```

### ch.lazy

The values of a channel until it is closed and drained. Each wait for a value obeys `timeout_ms`, and a timeout ends the terminal with `error("channel: timed out")`. A negative timeout is `RUNTIME-INVALID-DURATION` at the argument; `ch.lazy(0)` takes only what is already there. A channel cannot be read twice: a second terminal goes on with the values the first did not take (`ok([])` once it is drained), and a value a terminal took is gone, even when a later step dropped it. `take`, `first` and `find` take no value they do not need; `take_while` consumes the first value its block rejects.

```agentica
def produce(ch: Channel[Int]) -> Void
  for i in 1..6
    ch.send(i, 1000).unwrap!
  end
  ch.close
end

def main() -> Void
  ch: Channel[Int] = Channel.new(2)
  Task.spawn(&produce, ch)
  values = ch.lazy(1000)
  puts(values.first(2))
  puts(values.map do |n| n * n end.to_a)
end
```

```output
ok([1, 2])
ok([9, 16, 25, 36])
```

## map, select and flat_map

```text
Lazy.map(lazy: Lazy[A], f: Fn[A, B]) -> Lazy[B]
Lazy.filter(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.flat_map(lazy: Lazy[A], f: Fn[A, List[B]]) -> Lazy[B]
```

`select` is the method of `Lazy.filter`. `flat_map` gives the items of the lists its block returns, in order. There is no `filter_map`: write `select` then `map`.

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.lazy.select do |x| x % 2 == 0 end.map do |x| x * 10 end.to_a)
  puts(xs.lazy.flat_map do |x| [x, -x] end.first(5))
end
```

```output
ok([20, 40])
ok([1, -1, 2, -2, 3])
```

## take, take_while, drop and drop_while

```text
Lazy.take(lazy: Lazy[A], count: Int) -> Lazy[A]
Lazy.take_while(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.drop(lazy: Lazy[A], count: Int) -> Lazy[A]
Lazy.drop_while(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
```

A negative count is `RUNTIME-INVALID-COUNT` at the argument. `take_while` stops at the first item its block rejects; `drop_while` stops calling its block at the first item it rejects.

```agentica
def main() -> Void
  naturals = Lazy.produce(1) do |n| n + 1 end
  puts(naturals.drop(2).take(3).to_a)
  puts(naturals.take_while do |n| n < 4 end.to_a)
  puts([1, 5, 2, 7].lazy.drop_while do |n| n < 3 end.to_a)
end
```

```output
ok([3, 4, 5])
ok([1, 2, 3])
ok([5, 2, 7])
```

## with_index

```text
Lazy.with_index(lazy: Lazy[A], f: Fn[A, Int, B]) -> Lazy[B]
```

Maps each item with its index, from 0. To keep the item and the index together, return a struct.

```agentica
def main() -> Void
  puts(["a", "b", "c"].lazy.with_index do |s, i| "#{i}:#{s}" end.to_a)
end
```

```output
ok(["0:a", "1:b", "2:c"])
```

## each_slice, each_cons and chunk_while

```text
Lazy.each_slice(lazy: Lazy[A], size: Int) -> Lazy[List[A]]
Lazy.each_cons(lazy: Lazy[A], size: Int) -> Lazy[List[A]]
Lazy.chunk_while(lazy: Lazy[A], f: Fn[A, A, Bool]) -> Lazy[List[A]]
```

`each_slice` gives slices of `size` items, the last one shorter. `each_cons` gives every window of `size` neighbours, and nothing when the source has fewer. `chunk_while` starts a new group where its block is false for two neighbours. A size below 1 is `RUNTIME-INVALID-COUNT` at the argument.

```agentica
def main() -> Void
  xs = [1, 2, 4, 5, 6, 9]
  puts(xs.lazy.each_slice(4).to_a)
  puts(xs.lazy.each_cons(3).first(2))
  puts(xs.lazy.chunk_while do |a, b| b == a + 1 end.to_a)
end
```

```output
ok([[1, 2, 4, 5], [6, 9]])
ok([[1, 2, 4], [2, 4, 5]])
ok([[1, 2], [4, 5, 6], [9]])
```

## to_a and first

```text
Lazy.to_a(lazy: Lazy[A]) -> Result[List[A]]
Lazy.first(lazy: Lazy[A], count: Int) -> Result[List[A]]
```

`first(n)` is `take(n)` then `to_a`: at most `n` items, fewer when the source ends.

```agentica
def main() -> Void
  puts([1, 2].lazy.first(5))
  puts((1..3).lazy.map do |n| n * n end.to_a)
end
```

```output
ok([1, 2])
ok([1, 4, 9])
```

## each

```text
Lazy.each(lazy: Lazy[A], f: Fn[A, Result[Void]]) -> Result[Void]
```

The block returns `ok()` to go on, or an `error` that stops the pipeline and is the result, as in `File.each_line`. `try` works in the block.

```agentica
def main() -> Void
  result = Lazy.produce(1) do |n| n + 1 end.each do |n|
    if n > 2
      return error("stopped at #{n}")
    end
    puts(n)
    ok()
  end
  puts(result)
end
```

```output
1
2
error("stopped at 3")
```

## reduce and find

```text
Lazy.reduce(lazy: Lazy[A], initial: B, f: Fn[B, A, B]) -> Result[B]
Lazy.find(lazy: Lazy[A], f: Fn[A, Bool]) -> Result[A]
```

`reduce` folds from the left, as `List.reduce`. `find` gives the first item its block accepts, or `error("not found")` when the source ends, as `List.find`.

```agentica
def main() -> Void
  puts((1..4).lazy.reduce(0) do |total, n| total + n end)
  puts(Lazy.produce(1) do |n| n * 2 end.find do |n| n > 100 end)
  puts([1, 2].lazy.find do |n| n > 5 end)
end
```

```output
ok(10)
ok(128)
error("not found")
```

## write_lines

```text
Lazy.write_lines(lazy: Lazy[String], path: String, timeout_ms: Int) -> Result[Void]
```

Writes each item and a line feed to a file, created or truncated, and gives `ok()` at the end. The file opens before the first item is pulled, so a failed open reads nothing, and it is flushed and closed before the terminal returns, whatever ended it: the end of the items, a failed `try` or a failed write. A crash or cancel of the task closes it when the task ends. What was written before an error stays in the file. Lines are buffered and written 64 KiB at a time; `timeout_ms` bounds the open, each write and the close. A bad timeout or path, a failed open, write or close, and a line over 1 MiB end the terminal with that error. A line holding a line feed reads back as two lines with `File.foreach`.

```agentica {mode="check"}
def amount(line: String) -> Result[Int]
  return line.split(",")[1].to_i
end

def main() -> Void
  done = File.foreach("ledger.csv", 4096, 1000).drop(1).map do |line|
    "#{try amount(line) * 100}"
  end.write_lines("cents.txt", 1000)
  puts(done)
end
```

## Zlib steps

```text
Lazy.deflate(lazy: Lazy[List[Int]], level: Int = 6, raw: Bool = false) -> Lazy[List[Int]]
Lazy.inflate(lazy: Lazy[List[Int]], raw: Bool = false, max_bytes: Int = 1073741824) -> Lazy[List[Int]]
Lazy.gzip(lazy: Lazy[List[Int]], level: Int = 6) -> Lazy[List[Int]]
Lazy.gunzip(lazy: Lazy[List[Int]], max_bytes: Int = 1073741824) -> Lazy[List[Int]]
Lazy.write_bytes(lazy: Lazy[List[Int]], path: String, timeout_ms: Int = 30000) -> Result[Int]
```

The steps compress or decompress a stream of byte chunks, such as the chunks of `File.chunks`, which reads a regular file `size` bytes (1 to 16777216) at a time; `write_bytes` writes the chunks to a file, created or truncated, and gives the bytes written. A decoder error, output past `max_bytes`, a bad `level` and a byte outside 0 to 255 end the terminal with that error; a run that stops early frees its zlib streams. [Zlib](/library/text-and-data/zlib/#streams) has the details.

```agentica
def main() -> Void
  packed = [[104, 105], [], [33]].lazy.gzip.to_a.unwrap!
  puts(packed.lazy.gunzip.to_a)
end
```

```output
ok([[104, 105, 33]])
```

## try in the blocks

A failed `try` in any block of a `Lazy` method (a step, `Lazy.produce`, a terminal) ends the pipeline: no later item is pulled, a file the run opened is closed, and the terminal returns the error. A `try` that succeeds gives its value, so the block still gives a plain item. A block nested in that block, such as the block of a `List.map`, follows the usual rule: `try` there needs a block that returns a `Result` (`CHECK-TRY-CONTEXT`).

```agentica
def parse(text: String) -> Result[Int]
  return text.to_i
end

def main() -> Void
  words = ["1", "2", "x", "4"]
  puts(words.lazy.map do |word| try parse(word) * 10 end.first(2))
  puts(words.lazy.map do |word| try parse(word) * 10 end.to_a)
  puts(words.lazy.reduce(0) do |sum, word| sum + try parse(word) end)
end
```

```output
ok([10, 20])
error("cannot convert \"x\" to Int")
error("cannot convert \"x\" to Int")
```
