---
title: Stream
weight: 5
description: Build lazy pipelines over file lines or generated values.
---

`Stream[T]` is an immutable recipe. Creating a source or adding a step does no work; each terminal starts a fresh run from the source.

Use `Stream.iterate` for a generated sequence and combine it with lazy steps:

```agentica
def next(n: Int) -> Int
  return n + 1
end

def even(n: Int) -> Bool
  return n % 2 == 0
end

def add(total: Int, n: Int) -> Int
  return total + n
end

def main() -> Void
  values = Stream.iterate(1, &next).filter(&even).take(3)
  puts(values.to_list(3))
  puts(values.reduce(0, &add))
end
```

```output
ok([2, 4, 6])
ok(12)
```

`iterate` is endless, so bound it with `take` or use another step that can stop.

For a file, `Stream.lines(path, buffer_bytes, timeout_ms)` gives a lazy source of lines. It uses the same buffer range, UTF-8 checks, per-read timeout and close behavior as [`File.each_line`](/library/io-and-system/files/). The file opens when a terminal starts; each terminal opens it again.

The steps are `.map(f)`, `.filter(f)`, `.take(count)` and `.take_while(f)`. The terminals are `.to_list(max)`, `.each(f)` and `.reduce(initial, f)`. All terminals return a `Result`; `each` callbacks return `Result[Void]`, where `ok()` continues and `error(message)` stops. `to_list(max)` returns an error if there are more than `max` items and never collects past that bound. `take(0)` and `to_list(0)` do not pull from the source.

Choose [`File.each_line`](/library/io-and-system/files/) when a block should handle every line directly. Use `Stream.lines` when lazy steps should filter or limit lines before a terminal.
