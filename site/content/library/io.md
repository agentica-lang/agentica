---
title: IO
weight: 6
description: Print to standard output and error, and read standard input.
---

`puts`, `print`, `gets` and `gets!` can be called without the `IO.` prefix.
Output is buffered; call `IO.flush()` when another program waits for your
output line by line.

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
  puts(text.split("\n").size)
end
```

```input
one
two
```

```output
2
```

## IO.read_bytes

```text
IO.read_bytes(count: Int) -> Result[List[Int]]
```

Reads up to `count` bytes, from 0 to 1048576. At the end of input it gives
`ok([])`.

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

Sends buffered standard output now.

```agentica
def main() -> Void
  puts("ready")
  IO.flush()
end
```

```output
ready
```
