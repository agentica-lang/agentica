# Bytes

`Bytes` is an immutable byte string: one byte for each item (a `List[Int]`
takes eight). Use it for data that is not text. An item reads as an `Int` in
`0..255`. `Bytes` is a reserved name (`CHECK-REDEFINED-NAME` for a struct, enum
or import alias).

There is no literal: write `"PK".bytes`, `Digest.hexdecode("504b0304").unwrap!`
or `Bytes.from_list([80, 75, 3, 4]).unwrap!`. `"text".bytes` on a literal
without interpolation is a constant made once at load, so it needs no module
constant to stay cheap in a loop.

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
```

- `==` and `!=` compare length and bytes. They are not constant time: compare
  MACs and tokens with `HMAC.secure_compare`. There is no `<`, and `b == "s"`
  is `CHECK-TYPE-MISMATCH`.
- A `Bytes` is a `Map` key or a `Set` item. It is not an `ATS` key
  (`CHECK-MAP-KEY-TYPE`).
- `"#{b}"` is `<Bytes 3>`; `b.inspect` is `<Bytes 3 616263>` (the first 32 bytes
  in hex).
- Not JSON: `JSON.encode(b)` is `CHECK-NOT-ENCODABLE`, and a `Bytes` field of a
  decode target is `CHECK-NOT-DECODABLE`. Write it as Base64 text first.
- `slice`, `take` and `drop` copy. `+` in a loop is quadratic: collect the parts
  in a list and call `Bytes.concat` once. To build bytes one at a time, build a
  `List[Int]` and call `Bytes.from_list` once.
- `Digest`, `HMAC`, `Cipher`, `CMAC`, `KDF`, `Base64`,
  `SecureRandom.random_bytes`, `IO.read_bytes`, `File.read_bytes`,
  `File.write_bytes`, `File.sha256`, `String.from_bytes`, `Zlib`,
  `File.chunks`, the Lazy byte steps, `TCP.send_bytes`, `TCP.recv_bytes`,
  `Process.send_bytes`, `Process.read_bytes` and `std/binary` take and return
  `Bytes`. The `Native` array builtins
  (`get_array_of_*`, `put_array_of_*`) use `List[Int]` or `List[Float]`: they
  hold 32- and 64-bit numbers, not bytes.
- `List.uniq`, `tally` and `group_by` take `Int` or `String` keys only: use a
  `Set[Bytes]` or a `Map[Bytes, _]`. `List[Bytes]` has no `==`.
