---
title: IO
weight: 1
description: Print to standard output and error, and read standard input.
---

`puts`, `print`, `gets` and `gets!` can be called without the `IO.` prefix.

On Linux, macOS and Windows:

- A print reaches a pipe or file without `IO.flush()`. The VM writes it as soon as the reader takes it.
- Reads from standard input, and writes to standard output or error, wait without stopping other tasks.
- Each stream keeps up to 64 KiB. When a pipe is full, the printing tasks wait their turn, in order. A print has no timeout, and one print is never split by another (a crash message too).
- Standard output and error that go to the same terminal or file (for example with `2>&1`) share one buffer, so `puts` and `IO.warn` keep their order. On Windows this holds when both descriptors are the same handle object.
- On Windows, text typed on a console reaches the program as UTF-8, whatever the console's code page.
- On Windows, after a stop signal and for the last error messages, a pipe or console gets one wait of up to 200 ms in all. So a reader that never reads cannot hold the exit.

On other systems, output is buffered, so call `IO.flush()` when another program waits for your output line by line. A read from standard input blocks the whole program until input arrives. A write to standard output or error blocks it until the reader takes the text.

## puts

```text
puts(value: T) -> Void
IO.puts(value: T) -> Void
```

Prints a value and a new line. Strings print as they are. Other values print as in interpolation.

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

Prints a value and a new line to standard error, not standard output. Use it for logs.

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

Prints the debug form of a value, and gives the value back.

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

Reads one line, without its terminator (LF, CR or CRLF). At the end of input it gives an error result. An empty line is `ok("")`.

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

Reads one line. It stops the program with `RUNTIME-END-OF-INPUT` at the end of input. It can drop its parentheses.

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

Tells whether input has ended. It peeks without consuming, and it can block until data or the end of input arrives. Reads have no timeout, and the step budget cannot interrupt blocking I/O.

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

Reads all the rest of the input, to the end. It cannot read one message from a peer that keeps standard input open.

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
IO.read_bytes(count: Int) -> Result[Bytes]
```

Waits for exactly `count` bytes or the end of input, and gives them as a [`Bytes`](/library/data-structures/bytes/) with no decoding. `count` is from 0 to 1048576; zero gives empty bytes without consuming input. At the end of input the bytes are empty.

Text reads and byte reads share one input. Bytes that one of them takes are not seen by the other.

```agentica
def main() -> Void
  bytes = IO.read_bytes(2).unwrap!
  puts(bytes.to_a)
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

Sends buffered standard output now (standard error is not flushed). On Linux, macOS and Windows, the task waits until the output has reached the pipe or file. So it can wait when the reader is slow. It fails if the reader has gone away.

A program that speaks a protocol over standard input and output writes one compact JSON message per line, flushes after each reply, and sends its logs to `IO.warn` (standard error).

```agentica
def main() -> Void
  puts("ready")
  IO.flush()
end
```

```output
ready
```
