# Bytes

`Bytes` is an immutable byte string: one byte for each item (a `List[Int]`
takes eight). Use it for data that is not text. An item reads as an `Int` in
`0..255`. `Bytes` is a reserved name (`CHECK-REDEFINED-NAME` for a struct, enum
or import alias).

There is no literal: write `"PK".bytes`,
`OpenSSL.Digest.hexdecode("504b0304").unwrap!` or
`Bytes.from_list([80, 75, 3, 4]).unwrap!`. `"text".bytes` on a literal without
interpolation is a constant made once at load, so it needs no module constant
to stay cheap in a loop.

```text
s.bytes -> Bytes                          # UTF-8 bytes of a String
Bytes.from_list(list: List[Int]) -> Result[Bytes]   # error names the first item outside 0..255
b.to_a -> List[Int]                       # the way to map, select, reduce: Bytes has none
b.length, b.size -> Int
b.empty? -> Bool
b.at(i), b[i] -> Int                      # halts outside the bytes (RUNTIME-INDEX-OUT-OF-RANGE)
b.slice(start, length) -> Bytes           # halts outside the bounds
b.take(n), b.drop(n) -> Bytes             # clamp to the length; n < 0 is RUNTIME-INVALID-COUNT
a + b -> Bytes
Bytes.concat(parts: List[Bytes]) -> Bytes # one copy
b.each do |byte| ... end                  # Void
for byte in b ... end
b.decode(encoding) -> Result[String]      # text in an encoding; see below
s.encode(encoding) -> Result[Bytes]
```

- `decode` and `encode` take `utf-8`, `utf-16`, `utf-16le`, `utf-16be`,
  `utf-32`, `utf-32le`, `utf-32be`, `ascii`, `latin-1`, `iso-8859-15` and
  `windows-1252`, without case and with `_` as `-` (common aliases such as
  `utf8`, `latin1`, `cp1252` work). Plain `utf-16` and `utf-32` read and drop a
  byte order mark (big-endian without one) and write one; the other forms keep a
  mark as U+FEFF. Errors are strict and end with `at byte N` (decode) or `at
  index N` (encode); an unknown name is an error too. For UTF-8, use `s.bytes`
  and `String.from_bytes`.

- `==` and `!=` compare length and bytes. They are not constant time: compare
  MACs and tokens with `OpenSSL.HMAC.secure_compare`. There is no `<`, and
  `b == "s"` is `CHECK-TYPE-MISMATCH`.
- A `Bytes` is a `Map` key, an `ATS` key or a `Set` item.
- Not JSON: `JSON.encode(b)` is `CHECK-NOT-ENCODABLE`, and a `Bytes` field of a
  decode target is `CHECK-NOT-DECODABLE`. Write it as Base64 text first.
- `slice`, `take` and `drop` copy. `+` in a loop is quadratic: collect the parts
  in a list and call `Bytes.concat` once. To build bytes one at a time, build a
  `List[Int]` and call `Bytes.from_list` once.
- The `OpenSSL` family, `Base64`, `Zlib`, the `*_bytes` calls of `IO`,
  `File`, `TCP` and `Process`, and `std/binary` take and return `Bytes`. The
  `Native` array builtins use `List[Int]` or `List[Float]`, not bytes.
- `List.uniq`, `tally` and `group_by` take `Int` or `String` keys only: use a
  `Set[Bytes]` or a `Map[Bytes, _]`. `==` compares a `List[Bytes]` item by
  item.
