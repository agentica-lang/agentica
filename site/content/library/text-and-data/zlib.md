---
title: Zlib
weight: 7
description: The Zlib builtins, which compress bytes, files and streams with DEFLATE, zlib and gzip.
---

`Zlib` holds the compression builtins: bytes and files in the zlib wrapper (RFC 1950, the Ruby and Python default) and in gzip (RFC 1952), plus incremental streaming that also speaks raw DEFLATE (RFC 1951). The VM computes them with zlib, the library it already links; nothing is written in Agentica.

Decoders are strict on purpose: one stream or member, with its checksum verified, and any unused or trailing bytes after it are an error. Unlike Python's `gzip.decompress`, concatenated members never decode: the second member is trailing bytes, and trailing bytes are rejected.

## Bytes

```text
Zlib.deflate(data: List[Int], level: Int, max_out_bytes: Int) -> Result[List[Int]]
Zlib.inflate(data: List[Int], max_out_bytes: Int) -> Result[List[Int]]
Zlib.gzip(data: List[Int], level: Int, max_out_bytes: Int) -> Result[List[Int]]
Zlib.gunzip(data: List[Int], max_out_bytes: Int) -> Result[List[Int]]
Zlib.crc32(data: List[Int], seed: Int = 0) -> Result[Int]
```

`Zlib.deflate` compresses bytes to the zlib wrapper and `Zlib.gzip` to gzip, with `level` 0 to 9; empty input is valid and gives the empty stream or member. `Zlib.inflate` and `Zlib.gunzip` decompress one stream or member, checking the Adler checksum (zlib) or the CRC and size (gzip). Empty compressed input fails.

```agentica {mode="check"}
def main() -> Void
  packed = Zlib.deflate([104, 105], 6, 1048576).unwrap!
  back = Zlib.inflate(packed, 1048576).unwrap!
  puts(Test.eq(back, [104, 105]))
  gz = Zlib.gzip([104, 105], 9, 1048576).unwrap!
  puts(Test.eq(Zlib.gunzip(gz, 1048576).unwrap!, [104, 105]))
end
```

```text
ok()
ok()
```

- One-shot `data` is at most 1048576 bytes and `max_out_bytes` is 1 to 1048576, otherwise a contract error. Output past the cap is an error.
- Bytes are a `List[Int]` from 0 to 255, as `Crypto.sha256`, `IO.read_bytes` and `File.read_bytes` use.
- `Zlib.crc32` is the CRC32 (RFC 1952) of `data` chained after `seed`: leave the seed out first (it is 0), then pass each next chunk the previous result, so gzip members and ZIP entries can be checksummed piece by piece. Empty input returns `seed` unchanged. `data` is at most 1048576 bytes and `seed` is 0 to 4294967295, otherwise a contract error.

```agentica {mode="check"}
def main() -> Void
  digits: List[Int] = [49, 50, 51, 52, 53, 54, 55, 56, 57]
  empty: List[Int] = []
  puts(Test.eq(Zlib.crc32(digits, 0).unwrap!, 3421780262))
  first = Zlib.crc32(List.take(digits, 3), 0).unwrap!
  puts(Test.eq(Zlib.crc32(List.drop(digits, 3), first).unwrap!, 3421780262))
  puts(Test.eq(Zlib.crc32(empty, 4294967295).unwrap!, 4294967295))
end
```

```text
ok()
ok()
ok()
```

## Files

```text
Zlib.deflate_file(src: String, dst: String, level: Int, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.inflate_file(src: String, dst: String, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.gzip_file(src: String, dst: String, level: Int, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.gunzip_file(src: String, dst: String, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
```

The four file functions compress a file or decompress one stream or member from it into a new file at `dst`, and return the bytes written. They stream in fixed 64 KiB chunks with O(chunk) memory, so an archive far over the 1 MiB text cap still converts without holding it in memory.

```agentica {mode="check"}
def main() -> Void
  case Zlib.gzip_file("notes.txt", "notes.txt.gz", 6, 1073741824, 30000)
    ok(bytes) -> puts("#{bytes} bytes written")
    error(message) -> IO.warn("cannot compress: #{message}")
  end
end
```

```text
ok(38 bytes written)
```

- The raw input of compression never exceeds 1073741824 bytes and the compressed input of decompression never exceeds 268435456 bytes, enforced while reading even when the source grows. `max_out_bytes` is 1 to 1073741824, and output past it is cut while streaming so a partial file never grows past it and is kept on error.
- The source is read like `File.sha256` reads it (regular files only, read from the first byte); the destination opens like `create_private`, so an existing path is an error and stays intact. `timeout_ms` covers the whole call; expiry or a cancel detaches like the other whole-file calls, while work already running runs to its end and its result is dropped.
- Only the file functions carry the filesystem effect: with `--deny-fs` (or `--sandbox`) they return an error that begins with `denied: --deny-fs`, while the bytes and streaming calls run anywhere.

## Streaming

```text
Zlib.deflate_init(window_bits: Int, level: Int, max_total_in: Int, max_total_out: Int) -> Result[ZlibEncoder]
Zlib.inflate_init(window_bits: Int, max_total_in: Int, max_total_out: Int) -> Result[ZlibDecoder]
Zlib.deflate_next(enc: ZlibEncoder, data: List[Int], max_out: Int) -> Result[ZlibProgress]
Zlib.inflate_next(dec: ZlibDecoder, data: List[Int], max_out: Int) -> Result[ZlibProgress]
Zlib.deflate_finish(enc: ZlibEncoder, max_out: Int) -> Result[ZlibProgress]
Zlib.inflate_finish(dec: ZlibDecoder) -> Result[Void]
Zlib.encoder_close(enc: ZlibEncoder) -> Result[Void]
Zlib.decoder_close(dec: ZlibDecoder) -> Result[Void]
```

The streaming calls compress or decompress in bounded steps: `window_bits` 15 is the zlib wrapper, -15 raw DEFLATE and 31 gzip. Each total cap is 1 to 1073741824, enforced before the output or state could exceed it, and each call takes at most 65536 input bytes with room for `max_out` 1 to 65536 output bytes. A refused encoder quantum changes nothing and may run again with a smaller positive `max_out`; a decoder at its exact output budget still completes a trailer that produces no bytes, while a true overflow fails without returning extra bytes.

```agentica {mode="check"}
def pump(enc: ZlibEncoder, data: List[Int]) -> List[Int]
  out: List[Int] = []
  rest: List[Int] = data
  while rest.size > 0
    step = Zlib.deflate_next(enc, List.take(rest, 7), 1).unwrap!
    out = List.concat(out, step.output)
    rest = List.drop(rest, step.consumed)
  end
  again = true
  while again
    tail = Zlib.deflate_finish(enc, 1).unwrap!
    out = List.concat(out, tail.output)
    again = not tail.finished
  end
  return out
end

def main() -> Void
  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!
  packed = pump(enc, [104, 105])
  Zlib.encoder_close(enc).unwrap!
  puts(Test.eq(Zlib.inflate(packed, 1048576).unwrap!, [104, 105]))
end
```

```text
ok()
```

- Each step gives a `ZlibProgress(output, consumed, finished, needs_input)`, in that field order. `consumed` may be less than `data.size`; the caller owns the rest and presents it again, and trailing bytes after the stream end stay caller-owned through `consumed` and are never dropped.
- `needs_input` asks for more input (or a finish), never for a spin: when the codec may still drain output from its internal state after the input is exhausted it answers false, so the caller calls again with empty input and fresh room. Empty input is valid for drains. Repeat `deflate_finish` until `finished` is true; `inflate_finish` is `ok()` only once a whole checked stream end arrived, else a truncation error.
- Closing is idempotent, and feeding or finishing a closed, failed or finished handle is an error. Both handles move across tasks with `Task.spawn_owning`, and a task that ends frees what it did not close.
- `Zlib`, `ZlibEncoder`, `ZlibDecoder` and `ZlibProgress` are reserved type names.
