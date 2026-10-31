---
title: Bytes
weight: 7
description: Bytes, a compact immutable byte string, and the methods that read, cut and join it.
---

`Bytes` holds data that is not text: digests, file contents, wire formats. It stores one byte for each item, where a `List[Int]` of the same data takes eight. A byte is read as an `Int` from 0 to 255. `Bytes` is immutable, like every value: a method gives a new value. `Bytes` is a reserved name, so a struct, an enum or an import alias cannot be called `Bytes`.

There is no literal. Make a value with `s.bytes` (the UTF-8 bytes of a `String`), [`Digest.hexdecode`](/library/text-and-data/base64/#hex) or `Bytes.from_list`. `"text".bytes` on a string literal without interpolation is a constant, made once when the program loads, so writing it inside a loop costs nothing more than a named constant. Binary data that is not UTF-8 text comes from `Bytes.from_list` or `Digest.hexdecode`.

```agentica
def main() -> Void
  data = "héllo".bytes
  puts(data.length)
  puts(data[0])
  puts(data.to_a)
end
```

```output
6
104
[104, 195, 169, 108, 108, 111]
```

Two `Bytes` are equal when they have the same length and the same bytes. `==` is not constant time, so compare a MAC or a token with [`HMAC.secure_compare`](/library/text-and-data/crypto/). A `Bytes` never equals a `String`. There is no `<`. A `Bytes` can be a `Map` key or a `Set` item, so a cache can be keyed by a digest. It is not JSON: `JSON.encode` and `JSON.decode` refuse it with `CHECK-NOT-ENCODABLE` and `CHECK-NOT-DECODABLE`; write it as text first with `Base64.strict_encode64`. It cannot be an `ATS` key. `List.uniq`, `tally` and `group_by` take `Int` or `String` keys only, so for a `Bytes` use a `Set[Bytes]` or a `Map[Bytes, _]`.

```agentica
def main() -> Void
  a = "abc".bytes
  puts(a == "abc".bytes)
  puts(a != "abd".bytes)
  seen = Set.new([a, "abc".bytes, "xyz".bytes])
  puts(seen.size)
  puts(a)
  puts(a.inspect)
end
```

```output
true
true
2
<Bytes 3>
<Bytes 3 616263>
```

`to_s` and interpolation give `<Bytes 3>`, the length only, since raw bytes are not text. `inspect` and the text of a `Bytes` inside a list or map also show the first 32 bytes in hex, then `...` if there are more.

## bytes

```text
String.bytes(s: String) -> Bytes
```

The UTF-8 bytes of the text. `Bytes` has no `chars`: `s.bytes.to_a` is the list of integers.

## decode

```text
Bytes.decode(bytes: Bytes, encoding: String) -> Result[String]
```

Reads the bytes as text in an encoding: `utf-8`, `utf-16`, `utf-16le`, `utf-16be`, `utf-32`, `utf-32le`, `utf-32be`, `ascii` or `latin-1` (ISO-8859-1). A name is matched without case, with `_` read as `-`, and these aliases work too: `utf8`, `utf16`, `utf32`, `utf-16-le`, `utf-16-be`, `utf-32-le`, `utf-32-be`, `us-ascii`, `latin1`, `iso-8859-1`, `iso8859-1`, `l1` and `cp819`. An unknown name gives an error Result; the `agentica-lang/charset` package reads the other encodings. [`text.encode(encoding)`](/library/text-and-data/string/#encode) goes the other way.

Plain `utf-16` and `utf-32` read a byte order mark and drop it, and read big-endian when there is none, as the Unicode standard says (Python reads the byte order of the machine). The `le` and `be` forms and `utf-8` keep a mark as the character U+FEFF. Decoding is strict: the first byte or sequence the encoding does not allow (invalid UTF-8, an unpaired surrogate, a cut code unit, a value above U+10FFFF, a byte above 127 in ASCII) gives an error Result whose text ends with its offset, `at byte N`, counted from 0. Latin-1 reads every byte.

```agentica
def main() -> Void
  data = Bytes.from_list([255, 254, 104, 0, 233, 0]).unwrap!
  puts(data.decode("utf-16"))
  puts(Bytes.from_list([104, 233]).unwrap!.decode("Latin-1"))
  puts(Bytes.from_list([104, 0, 0, 220]).unwrap!.decode("utf-16le"))
  puts("x".bytes.decode("koi8-r").ok?)
end
```

```output
ok("hé")
ok("hé")
error("invalid UTF-16LE at byte 2")
false
```

## from_list

```text
Bytes.from_list(list: List[Int]) -> Result[Bytes]
```

Makes a `Bytes` from integers. An item outside 0 to 255 gives an error that names its index. To build bytes one at a time, build a `List[Int]` and call `from_list` once.

```agentica
def main() -> Void
  puts(Bytes.from_list([80, 75, 3, 4]).unwrap!.inspect)
  puts(Bytes.from_list([1, 256]).message)
end
```

```output
<Bytes 4 504b0304>
item 1 is 256, not a byte (0 to 255)
```

## to_a

```text
Bytes.to_a(bytes: Bytes) -> List[Int]
```

The bytes as a list of integers. `Bytes` has no `map`, `select` or `reduce`; `to_a` is the way to them, and it costs eight bytes of memory for each byte.

```agentica
def main() -> Void
  total = "abc".bytes.to_a.reduce(0) do |sum, byte|
    sum + byte
  end

  puts(total)
end
```

```output
294
```

## length and empty?

```text
Bytes.length(bytes: Bytes) -> Int
Bytes.empty?(bytes: Bytes) -> Bool
```

The number of bytes, and whether there are none. `size` is the same as `length`.

## at

```text
Bytes.at(bytes: Bytes, index: Int) -> Int
```

The byte at a zero-based index, as `b.at(i)` or `b[i]`. An index outside the bytes stops the program with `RUNTIME-INDEX-OUT-OF-RANGE`.

```agentica
def main() -> Void
  b = "AZ".bytes
  puts(b[0])
  puts(b.at(1))
end
```

```output
65
90
```

## slice, take and drop

```text
Bytes.slice(bytes: Bytes, start: Int, length: Int) -> Bytes
Bytes.take(bytes: Bytes, n: Int) -> Bytes
Bytes.drop(bytes: Bytes, n: Int) -> Bytes
```

`slice` copies a range and stops the program outside the bounds. `take` and `drop` copy the first `n` bytes or the rest, and never stop for a count above the length (a negative count is `RUNTIME-INVALID-COUNT`). All three copy: a result does not keep its source alive.

```agentica
def main() -> Void
  b = "abcdef".bytes
  puts(b.slice(1, 3).to_a)
  puts(b.take(2).to_a)
  puts(b.drop(4).to_a)
  puts(b.take(99).length)
end
```

```output
[98, 99, 100]
[97, 98]
[101, 102]
6
```

## + and concat

```text
a + b
Bytes.concat(parts: List[Bytes]) -> Bytes
```

`+` joins two values. Repeated `+` copies everything each time, so a loop that joins many parts takes quadratic time; join the parts with `Bytes.concat`, which copies once.

```agentica
def main() -> Void
  puts(("ab".bytes + "cd".bytes).to_a)
  puts(Bytes.concat(["a".bytes, "b".bytes, "c".bytes]).to_a)
end
```

```output
[97, 98, 99, 100]
[97, 98, 99]
```

## each and for

```text
Bytes.each(bytes: Bytes, f: Fn[Int, Void]) -> Void
```

Calls the block with each byte in order. `for byte in b` does the same and allows assignment in the body.

```agentica
def main() -> Void
  sum = 0
  for byte in "abc".bytes
    sum += byte
  end

  puts(sum)
  "ab".bytes.each do |byte|
    puts(byte)
  end
end
```

```output
294
97
98
```
