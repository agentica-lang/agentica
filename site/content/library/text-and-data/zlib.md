---
title: Zlib
weight: 7
description: The Zlib builtins and the Lazy steps, which compress bytes, files and streams with DEFLATE, zlib and gzip.
---

`Zlib` holds the compression builtins for bytes in the zlib wrapper (RFC 1950, the Ruby and Python default) and in gzip (RFC 1952). Files and streams go through [Lazy](/library/data-structures/lazy/#zlib-steps) steps, which also speak raw DEFLATE (RFC 1951). The VM computes them with zlib, the library it already links; nothing is written in Agentica.

There is no auto-detect, no dictionary and no metadata option. Decoders are strict on purpose: one stream or member, with its checksum verified, and any trailing byte after it is an error. Unlike Python's `gzip.decompress`, concatenated members never decode: the second member is trailing bytes.

## Bytes

```text
Zlib.deflate(data: Bytes, level: Int = 6, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.inflate(data: Bytes, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.gzip(data: Bytes, level: Int = 6, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.gunzip(data: Bytes, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.crc32(data: Bytes, seed: Int = 0) -> Result[Int]
```

`Zlib.deflate` compresses bytes to the zlib wrapper and `Zlib.gzip` to gzip, with `level` 0 to 9; empty input is valid and gives the empty stream or member. `Zlib.inflate` and `Zlib.gunzip` decompress one stream or member, checking the Adler checksum (zlib) or the CRC and size (gzip). Empty compressed input fails.

```agentica {mode="check"}
def main() -> Void
  packed = Zlib.deflate("hi".bytes).unwrap!
  puts(Test.eq(Zlib.inflate(packed).unwrap!, "hi".bytes))
  gz = Zlib.gzip("hi".bytes, 9).unwrap!
  puts(Test.eq(Zlib.gunzip(gz, 2).unwrap!, "hi".bytes))
end
```

```text
ok()
ok()
```

- `data` is at most 1048576 bytes and `max_bytes`, the cap of the output, is 1 to 1048576; output past it is an error.
- The data is [`Bytes`](/library/data-structures/bytes/), as `s.bytes`, `IO.read_bytes` and `File.read_bytes` give it; `Bytes.from_list` makes it from a `List[Int]`.
- `Zlib.crc32` is the CRC32 (RFC 1952) of `data` chained after `seed`: leave the seed out first (it is 0), then pass each next chunk the previous result, so gzip members and ZIP entries can be checksummed piece by piece. Empty input returns `seed` unchanged. `data` is at most 1048576 bytes and `seed` is 0 to 4294967295, otherwise a contract error.

```agentica {mode="check"}
def main() -> Void
  digits = "123456789".bytes
  puts(Test.eq(Zlib.crc32(digits).unwrap!, 3421780262))
  first = Zlib.crc32(digits.take(3)).unwrap!
  puts(Test.eq(Zlib.crc32(digits.drop(3), first).unwrap!, 3421780262))
  puts(Test.eq(Zlib.crc32("".bytes, 4294967295).unwrap!, 4294967295))
end
```

```text
ok()
ok()
ok()
```

## Streams

```text
File.chunks(path: String, size: Int = 65536, timeout_ms: Int = 30000) -> Lazy[Bytes]
lazy.deflate(level: Int = 6, raw: Bool = false) -> Lazy[Bytes]
lazy.inflate(raw: Bool = false, max_bytes: Int = 1073741824) -> Lazy[Bytes]
lazy.gzip(level: Int = 6) -> Lazy[Bytes]
lazy.gunzip(max_bytes: Int = 1073741824) -> Lazy[Bytes]
lazy.write_bytes(path: String, timeout_ms: Int = 30000) -> Result[Int]
```

A stream is a `Lazy[Bytes]` of byte chunks. `File.chunks` reads a regular file in chunks of `size` bytes (1 to 16777216), the four steps compress or decompress the chunks that pass, and `write_bytes` writes them to a file, created or truncated, and returns the bytes written. Memory stays bounded by a chunk, so a file far over the 1 MiB cap of the bytes calls converts without being held in memory.

```agentica {mode="check"}
def main() -> Void
  case File.chunks("notes.txt").gzip.write_bytes("notes.txt.gz")
    ok(bytes) -> puts("#{bytes} bytes written")
    error(message) -> IO.warn("cannot compress: #{message}")
  end

  puts(File.chunks("notes.txt.gz").gunzip.reduce(0) do |n, chunk| n + chunk.size end)
end
```

- `raw: true` is raw DEFLATE, with no wrapper and no checksum. Chunks of any size are taken, empty ones too; an output chunk is at most 65536 bytes.
- A decoder's `max_bytes` (at least 1) caps its whole output while it streams: the run ends with an error before a byte past it is handed on. Truncation, a bad checksum and a trailing byte end the run with an error too, and a bad `level` or `max_bytes` is the error of the run.
- The run ends with the first error, and a run that stops early (`first`, `find`, a failed `try` in a block, an error or a cancel) frees its zlib stream and closes its file.
- Only `File.chunks` and `write_bytes` carry the filesystem effect: with `--deny-fs` (or `--sandbox`) they give an error that begins with `denied: --deny-fs`, while the steps and the bytes calls run anywhere.
- `Zlib` is a reserved type name.
