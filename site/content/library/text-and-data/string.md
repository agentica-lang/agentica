---
title: String
weight: 1
description: Functions for text. Each one is also a method on String values.
---

Strings are Unicode text. Lengths and indexes count characters, not bytes; `bytesize` counts the UTF-8 bytes.

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

## length and empty?

```text
String.length(s: String) -> Int
String.empty?(s: String) -> Bool
```

`length` counts Unicode characters. `empty?` is true when there are none.

```agentica
def main() -> Void
  puts("hello".length)
  puts(String.length("café"))
  puts("".empty?)
  puts("hello".empty?)
end
```

```output
5
4
true
false
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
String.index_of(s: String, part: String) -> Optional[Int]
```

Finds the first match as `some(index)`, counted in characters (`some(0)` for an empty part). Missing text gives `none`.

```agentica
def main() -> Void
  puts("banana".index_of("na"))
  puts("banana".index_of("x").none?)
end
```

```output
some(2)
true
```

## at

```text
String.at(s: String, index: Int) -> String
```

Gives one character. Indexes start at 0. An index outside the string stops the program with `RUNTIME-INDEX-OUT-OF-RANGE`.

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

`code` gives the Unicode number of a one-character string. `from_code` goes the other way, from a scalar value (0 to 0x10FFFF, no surrogates). Other input stops the program with `RUNTIME-INVALID-CHARACTER`.

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

`to_float` also reads an exponent (`1.5E-3`, `1e+20`) and the text `to_s` writes for infinity and NaN (`+inf.0`, `-inf.0`, `+nan.0`), so `x.to_s.to_f` gives `x` back (a NaN reads back as NaN). It rounds to the nearest Float, and a value past the range becomes an infinity or zero. `Infinity`, `.5` and `1_000.0` are errors.

```agentica
def main() -> Void
  puts(String.to_int("-12"))
  puts("3.5".to_f)
  puts("1e+20".to_f)
  puts("-inf.0".to_f)
  puts("abc".to_i.ok?)
end
```

```output
ok(-12)
ok(3.5)
ok(1e+20)
ok(-inf.0)
false
```

## to_int! and to_float!

```text
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
```

Like `to_int` and `to_float`, but give the number itself and stop the program on bad text: `RUNTIME-INVALID-NUMBER` for text that is not a number (`1e`, `.5`, ` 1`, `1_000.0` and `Infinity` for `to_float!`), and `RUNTIME-INTEGER-OVERFLOW` for an integer outside `Int`.

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
String.from_bytes(data: Bytes) -> Result[String]
```

Decodes UTF-8 bytes strictly: invalid, overlong, surrogate and incomplete sequences give an error Result, never replacement characters. It is the inverse of [`s.bytes`](#bytes). [`b.decode(encoding)`](/library/data-structures/bytes/#decode) reads the other encodings.

```agentica
def main() -> Void
  puts(String.from_bytes("hi".bytes))
  puts(String.from_bytes(Bytes.from_list([255]).unwrap!).ok?)
end
```

```output
ok("hi")
false
```

## bytes

```text
String.bytes(s: String) -> Bytes
```

Encodes the text as UTF-8, as a [`Bytes`](/library/data-structures/bytes/). It cannot fail, and `String.from_bytes` turns it back into the text. `s.bytes.to_a` gives the bytes as a list of integers from 0 to 255.

```agentica
def main() -> Void
  b = "hé".bytes
  puts(b.length)
  puts(b.to_a)
end
```

```output
3
[104, 195, 169]
```

## encode

```text
String.encode(s: String, encoding: String) -> Result[Bytes]
```

Writes the text as bytes in an encoding, named as for [`Bytes.decode`](/library/data-structures/bytes/#decode): UTF-8, UTF-16, UTF-32, ASCII or Latin-1. Plain `utf-16` and `utf-32` write a byte order mark and then big-endian units; the `le` and `be` forms write no mark. A character that ASCII or Latin-1 cannot hold gives an error Result whose text ends with its index in the text, `at index N`, and an unknown name gives an error too. The Unicode encodings never fail. For UTF-8, use [`.bytes`](#bytes) and [`String.from_bytes`](#from_bytes).

```agentica
def main() -> Void
  puts("hé".encode("utf-16le").unwrap!.to_a)
  puts("hé".encode("utf-16").unwrap!.to_a)
  puts("hé".encode("latin-1").unwrap!.to_a)
  puts("h€".encode("latin-1"))
end
```

```output
[104, 0, 233, 0]
[254, 255, 0, 104, 0, 233]
[104, 233]
error("cannot encode U+20AC in Latin-1 at index 1")
```

## bytesize

```text
String.bytesize(s: String) -> Int
```

Counts the UTF-8 bytes of the text, a NUL included (`"é".bytesize` is 2), as many as `s.bytes` gives, without building them. A C function that takes text with its length gets this count, with the text in a buffer of [`Native.from_string`](/library/io-and-system/native/types/#owned-buffers-and-typed-memory).

```agentica
def main() -> Void
  puts("hello".bytesize)
  puts("café".bytesize)
  puts("".bytesize)
end
```

```output
5
5
0
```
