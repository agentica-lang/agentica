---
title: IO
weight: 1
description: Print to standard output and error, and read standard input.
---

`puts`, `print`, `gets` and `gets!` can be called without the `IO.` prefix.
On Linux, macOS and Windows, a print reaches a pipe or file without `IO.flush()`: the VM writes it as soon as the reader takes it. On other systems output is buffered, so call `IO.flush()` when another program waits for your output line by line.

On Linux, macOS and Windows, a read from standard input waits without stopping other tasks. On other systems a read blocks the whole program until input arrives.

On Linux, macOS and Windows, writing to standard output or standard error also waits without stopping other tasks. Each stream keeps up to 64 KiB of output; when a pipe is full, the tasks that print wait their turn, in order, and the other tasks keep running. A print has no timeout, and the text of one print is never split by another print. Output on one stream keeps the order of the calls. When standard output and standard error go to the same terminal or file (for example with `2>&1`), they share one buffer, so `puts` and `IO.warn` appear in the order of the calls. On Windows two descriptors count as the same when they are the same handle object, for example one pipe given to both. When they go to different places, there is no order between them. A crash message from a task waits for room in the same way and is never put in the middle of a print. At the end of the run the program waits, within the flush limit, until the output has been written. On Windows, after a stop signal and for the last error messages, a pipe or console gets one wait of up to 200 ms in all to take what is left, so a reader that never reads cannot hold the exit. On other systems a write blocks the whole program until the reader takes it.

## puts

```text
puts(value: T) -> Void
IO.puts(value: T) -> Void
```

Prints a value and a new line. Strings print as they are; other values print
as in interpolation.

```agentica
def main() -> Void
  puts("text")
  IO.puts([1, 2])
end
```

```output
text
[1, 2]
```

## print

```text
print(value: T) -> Void
IO.print(value: T) -> Void
```

Prints without a new line.

```agentica
def main() -> Void
  print("a")
  print("b")
  puts("")
end
```

```output
ab
```

## IO.warn

```text
IO.warn(value: T) -> Void
```

Prints a value and a new line to standard error, not standard output. Use it
for logs.

```agentica
def main() -> Void
  IO.warn("this goes to stderr")
  puts("this goes to stdout")
end
```

```output
this goes to stdout
```

## IO.inspect

```text
IO.inspect(value: T) -> T
```

Prints the debug form of a value and gives the value back.

```agentica
def main() -> Void
  name = IO.inspect("Ana")
  puts(name.length)
end
```

```output
"Ana"
3
```

## gets

```text
gets() -> Result[String]
IO.gets() -> Result[String]
```

Reads one line, without its line ending. At the end of input it gives an error
Result. An empty line is `ok("")`.

```agentica
def main() -> Void
  first = gets()
  puts(first)
  second = gets()
  puts(second.ok?)
end
```

```input
hello
```

```output
ok("hello")
false
```

## gets!

```text
gets!() -> String
IO.gets!() -> String
```

Reads one line and stops the program at the end of input. It can drop its
parentheses.

```agentica
def main() -> Void
  name = gets!.strip
  puts("Hello, #{name}!")
end
```

```input
  Ana
```

```output
Hello, Ana!
```

## IO.eof?

```text
IO.eof?() -> Bool
```

Tells whether input has ended. It may wait for the next byte.

```agentica
def main() -> Void
  count = 0
  while !IO.eof?
    line = IO.gets!
    count += 1
  end
  puts("#{count} lines")
end
```

```input
a
b
c
```

```output
3 lines
```

## IO.read

```text
IO.read() -> String
```

Reads all the rest of the input.

```agentica
def main() -> Void
  text = IO.read()
  puts(text.split("\n"))
end
```

```input
one
two
```

```output
["one", "two", ""]
```

The last line ends with `\n`, so `split` gives an empty last part.

## IO.read_bytes

```text
IO.read_bytes(count: Int) -> Result[List[Int]]
```

Reads up to `count` bytes, from 0 to 1048576. At the end of input it gives
`ok([])`.

Text reads and byte reads share one input: bytes that one of them takes are not seen by the other.

```agentica
def main() -> Void
  bytes = IO.read_bytes(2).unwrap!
  puts(bytes)
  puts(String.from_bytes(bytes))
end
```

```input
hi
```

```output
[104, 105]
ok("hi")
```

## IO.flush

```text
IO.flush() -> Void
```

Sends buffered standard output now. On Linux, macOS and Windows the task waits until the output has reached the pipe or file, so it can wait when the reader is slow. It fails if the reader has gone away.

```agentica
def main() -> Void
  puts("ready")
  IO.flush()
end
```

```output
ready
```
