---
title: String
weight: 1
description: Functions for text. Each one is also a method on String values.
---

Strings are Unicode text. Lengths and indexes count characters, not bytes. Every function here is also a method: `String.trim(s)` is `s.trim`.

## Aliases

Some methods have Ruby names too:

| Method | Same as |
|---|---|
| `s.size` | `String.length(s)` |
| `s.strip` | `String.trim(s)` |
| `s.include?(x)` | `String.contains?(s, x)` |
| `s.start_with?(x)`, `s.end_with?(x)` | `String.starts_with?`, `String.ends_with?` |
| `s.to_i`, `s.to_i!` | `String.to_int(s)`, `String.to_int!(s)` |
| `s.to_f`, `s.to_f!` | `String.to_float(s)`, `String.to_float!(s)` |
| `xs.join(sep)` on a `List[String]` | `String.join(xs, sep)` |

## length

```text
String.length(s: String) -> Int
```

Counts Unicode characters.

```agentica
def main() -> Void
  puts("hello".length)
  puts(String.length("café"))
end
```

```output
5
4
```

## upcase and downcase

```text
String.upcase(s: String) -> String
String.downcase(s: String) -> String
```

```agentica
def main() -> Void
  puts("Hello".upcase)
  puts("Hello".downcase)
end
```

```output
HELLO
hello
```

## trim

```text
String.trim(s: String) -> String
```

Removes spaces, tabs and new lines at both ends.

```agentica
def main() -> Void
  puts("[" + "  hi \n".trim + "]")
end
```

```output
[hi]
```

## split

```text
String.split(s: String, separator: String) -> List[String]
```

Cuts text at each separator. Every part is kept, even an empty one at either end or between two separators, so `join` with the same separator gives the text back. Empty text gives `[""]`. An empty separator gives the characters.

```agentica
def main() -> Void
  puts("a,b,c".split(","))
  puts("a,,b,".split(","))
  puts("line\n".split("\n"))
  puts("".split(","))
  puts("a,,b,".split(",").join(","))
  puts("abc".split(""))
end
```

```output
["a", "b", "c"]
["a", "", "b", ""]
["line", ""]
[""]
a,,b,
["a", "b", "c"]
```

## join

```text
String.join(parts: List[String], separator: String) -> String
```

Puts the separator between the parts.

```agentica
def main() -> Void
  puts(String.join(["a", "b", "c"], "-"))
  puts(["x", "y"].join(", "))
end
```

```output
a-b-c
x, y
```

## contains?, starts_with? and ends_with?

```text
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
```

```agentica
def main() -> Void
  file = "report.txt"
  puts(file.contains?("port"))
  puts(file.starts_with?("rep"))
  puts(file.ends_with?(".csv"))
end
```

```output
true
true
false
```

## replace

```text
String.replace(s: String, from: String, to: String) -> String
```

Replaces every match.

```agentica
def main() -> Void
  puts("a-b-c".replace("-", "+"))
end
```

```output
a+b+c
```

## slice

```text
String.slice(s: String, start: Int, length: Int) -> String
```

Gives `length` characters starting at `start`. A range outside the text stops the program.

```agentica
def main() -> Void
  puts("Agentica".slice(0, 5))
  puts("Agentica".slice(5, 3))
end
```

```output
Agent
ica
```

## index_of

```text
String.index_of(s: String, part: String) -> Result[Int]
```

Finds the first match. Missing text gives an error Result.

```agentica
def main() -> Void
  puts("banana".index_of("na"))
  puts("banana".index_of("x").ok?)
end
```

```output
ok(2)
false
```

## at

```text
String.at(s: String, index: Int) -> String
```

Gives one character. Indexes start at 0. A bad index stops the program.

```agentica
def main() -> Void
  puts("hello".at(1))
end
```

```output
e
```

## reverse

```text
String.reverse(s: String) -> String
```

```agentica
def main() -> Void
  puts("stressed".reverse)
end
```

```output
desserts
```

## code and from_code

```text
String.code(c: String) -> Int
String.from_code(n: Int) -> String
```

`code` gives the Unicode number of a one-character string. `from_code` goes the other way.

```agentica
def main() -> Void
  puts("a".code)
  puts(String.from_code("a".code + 1))
end
```

```output
97
b
```

## compare

```text
String.compare(a: String, b: String) -> Int
```

Gives `-1`, `0` or `1`, in the order `sort` uses: by code point, so `"B"` comes before `"a"`. It is also a method: `a.compare(b)`.

```agentica
def main() -> Void
  puts("apple".compare("banana"))
  puts("b".compare("b"))
  puts("B".compare("a"))
end
```

```output
-1
0
-1
```

## from_int and from_float

```text
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
```

The same as `n.to_s` and `x.to_s`.

```agentica
def main() -> Void
  puts(String.from_int(42) + "!")
  puts(String.from_float(2.5) + "!")
end
```

```output
42!
2.5!
```

## to_int and to_float

```text
String.to_int(s: String) -> Result[Int]
String.to_float(s: String) -> Result[Float]
```

Read a signed decimal number. Bad text gives an error Result.

```agentica
def main() -> Void
  puts(String.to_int("-12"))
  puts("3.5".to_f)
  puts("abc".to_i.ok?)
end
```

```output
ok(-12)
ok(3.5)
false
```

## to_int! and to_float!

```text
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
```

Like `to_int` and `to_float`, but give the number itself and stop the program on bad text.

```agentica
def main() -> Void
  puts("40".to_i! + 2)
  puts("1.5".to_f! * 2.0)
end
```

```output
42
3.0
```

## from_bytes

```text
String.from_bytes(data: List[Int]) -> Result[String]
```

Decodes UTF-8 bytes. Invalid bytes give an error Result.

```agentica
def main() -> Void
  puts(String.from_bytes([104, 105]))
  puts(String.from_bytes([255]).ok?)
end
```

```output
ok("hi")
false
```
