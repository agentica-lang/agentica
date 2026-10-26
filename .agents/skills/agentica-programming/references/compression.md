# Compression

`Zlib`, `ZlibEncoder`, `ZlibDecoder` and `ZlibProgress` are reserved.
`deflate`/`inflate` are the zlib wrapper (RFC 1950), `gzip`/`gunzip` are gzip
(RFC 1952); streaming also speaks raw DEFLATE (RFC 1951) through
`window_bits` -15. Decoders take one stream or member with its checksum
verified; trailing bytes (a second member included) are an error, unlike
Python's `gzip.decompress`.

```text
Zlib.deflate(data: List[Int], level: Int, max_out_bytes: Int) -> Result[List[Int]]
Zlib.inflate(data: List[Int], max_out_bytes: Int) -> Result[List[Int]]
Zlib.gzip(data: List[Int], level: Int, max_out_bytes: Int) -> Result[List[Int]]
Zlib.gunzip(data: List[Int], max_out_bytes: Int) -> Result[List[Int]]
Zlib.deflate_file(src: String, dst: String, level: Int, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.inflate_file(src: String, dst: String, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.gzip_file(src: String, dst: String, level: Int, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.gunzip_file(src: String, dst: String, max_out_bytes: Int, timeout_ms: Int) -> Result[Int]
Zlib.deflate_init(window_bits: Int, level: Int, max_total_in: Int, max_total_out: Int) -> Result[ZlibEncoder]
Zlib.inflate_init(window_bits: Int, max_total_in: Int, max_total_out: Int) -> Result[ZlibDecoder]
Zlib.deflate_next(enc: ZlibEncoder, data: List[Int], max_out: Int) -> Result[ZlibProgress]
Zlib.inflate_next(dec: ZlibDecoder, data: List[Int], max_out: Int) -> Result[ZlibProgress]
Zlib.deflate_finish(enc: ZlibEncoder, max_out: Int) -> Result[ZlibProgress]
Zlib.inflate_finish(dec: ZlibDecoder) -> Result[Void]
Zlib.encoder_close(enc: ZlibEncoder) -> Result[Void]
Zlib.decoder_close(dec: ZlibDecoder) -> Result[Void]
Zlib.crc32(data: List[Int], seed: Int = 0) -> Result[Int]
```

- One-shot `data` is at most 1048576 bytes (empty input is valid for
  encoding); `max_out_bytes` is 1..1048576; `level` is 0..9.
- `Zlib.crc32` chains the CRC32 (RFC 1952) after `seed`: leave it out first (0),
  then pass each next chunk the previous result; empty input returns `seed`
  unchanged. `data` is at most 1048576 bytes, `seed` is 0..4294967295.
- File functions return the bytes written. The raw input of compression caps
  at 1073741824 bytes, the compressed input of decompression at 268435456
  bytes; `max_out_bytes` is 1..1073741824 and output past it is cut with the
  partial kept. Sources are regular files only; destinations open like
  `create_private`, so an existing path stays intact. Only the file
  functions take `--deny-fs`.
- Streaming `window_bits` is 15 (zlib), -15 (raw) or 31 (gzip); each total
  cap is 1..1073741824; each call takes at most 65536 input bytes with
  `max_out` 1..65536. Each step gives
  `ZlibProgress(output, consumed, finished, needs_input)`: `consumed` may be
  short of `data.size` (present the rest again), `needs_input` asks for more
  input or a finish (call again with empty input when it is false), and
  repeat `deflate_finish` until `finished`. `inflate_finish` is `ok()` only
  at a whole checked stream end. Closing is idempotent; feeding or finishing
  a closed, failed or finished handle is an error. Both handles move with
  `Task.spawn_owning` (`tasks.md`).
