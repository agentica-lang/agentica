# Compression

`Zlib`, `ZlibDecoder` and `ZlibProgress` are reserved. `deflate`/`inflate` are
the zlib wrapper (RFC 1950), `gzip`/`gunzip` are gzip (RFC 1952); the Lazy
steps also speak raw DEFLATE (RFC 1951) with `raw = true`. Decoders take one
stream or member with its checksum verified; trailing bytes (a second member
included) are an error, unlike Python's `gzip.decompress`.

```text
Zlib.deflate(data: List[Int], level: Int = 6, max_bytes: Int = 1048576) -> Result[List[Int]]
Zlib.inflate(data: List[Int], max_bytes: Int = 1048576) -> Result[List[Int]]
Zlib.gzip(data: List[Int], level: Int = 6, max_bytes: Int = 1048576) -> Result[List[Int]]
Zlib.gunzip(data: List[Int], max_bytes: Int = 1048576) -> Result[List[Int]]
Zlib.crc32(data: List[Int], seed: Int = 0) -> Result[Int]
File.chunks(path: String, size: Int = 65536, timeout_ms: Int = 30000) -> Lazy[List[Int]]
lazy.deflate(level: Int = 6, raw: Bool = false) -> Lazy[List[Int]]
lazy.inflate(raw: Bool = false, max_bytes: Int = 1073741824) -> Lazy[List[Int]]
lazy.gzip(level: Int = 6) -> Lazy[List[Int]]
lazy.gunzip(max_bytes: Int = 1073741824) -> Lazy[List[Int]]
lazy.write_bytes(path: String, timeout_ms: Int = 30000) -> Result[Int]
Zlib.inflate_init(window_bits: Int, max_total_in: Int, max_total_out: Int) -> Result[ZlibDecoder]
Zlib.inflate_next(dec: ZlibDecoder, data: List[Int], max_out: Int) -> Result[ZlibProgress]
Zlib.inflate_finish(dec: ZlibDecoder) -> Result[Void]
Zlib.decoder_close(dec: ZlibDecoder) -> Result[Void]
```

```ruby
def main() -> Void
  puts(File.chunks("notes.txt").gzip.write_bytes("notes.txt.gz"))   # ok(bytes written)
  total = File.chunks("notes.txt.gz").gunzip(1048576).reduce(0) do |n, chunk|
    n + chunk.size
  end
  puts(total)                                                 # ok(size of notes.txt)
  puts(Zlib.inflate(Zlib.deflate([104, 105]).unwrap!))        # ok([104, 105])
end
```

- One-shot `data` is at most 1048576 bytes (empty input is valid for
  encoding); `max_bytes` caps the output, 1..1048576; `level` is 0..9.
- `Zlib.crc32` chains the CRC32 (RFC 1952) after `seed`: leave it out first (0),
  then pass each next chunk the previous result; empty input returns `seed`
  unchanged. `data` is at most 1048576 bytes, `seed` is 0..4294967295.
- Arguments are positional: `.deflate(9, true)` is raw at level 9,
  `.inflate(true, cap)` raw with a cap.
- The steps take chunks of any size, empty ones too, and give chunks of at most
  65536 bytes. A decoder's `max_bytes` (at least 1) holds while it streams.
  Truncation, a checksum, a trailing byte, the cap, a bad `level` or
  `max_bytes` end the terminal with an error Result that begins `zlib: `.
- A run that stops early (`first`, `find`, a failed `try`, an error, a cancel)
  frees its zlib streams and closes its files.
- `File.chunks` reads regular files only, `size` is 1..16777216 (outside it is
  `RUNTIME-INVALID-COUNT`); `write_bytes` creates or truncates (`lazy.md`).
  Only these two take `--deny-fs`; the steps and `Zlib` calls run anywhere.
- The streaming decoder (`inflate_init` ... `decoder_close`) is kept for now;
  the Lazy steps will replace it. Prefer `gunzip`/`inflate` on `File.chunks`.
  `window_bits` is 15, -15 or 31; each call takes at most 65536 bytes with
  `max_out` 1..65536; present the unconsumed rest again, and call again with
  empty input while `needs_input` is false.
