# Archive (`std/archive`)

`import Archive from "std/archive"`. Copies an explicit allowlist of regular
files out of a plain `.tar`, gzipped `.tar.gz`, or classic single-disk
`.zip` (stored and raw deflate only) into a new private directory. Written
in Agentica over `File.chunks` and the Lazy zlib steps; every failure is an `error`
and none halts, whatever the input.

```text
Archive.options() -> Archive.Options
Archive.extract_tar(src, members, dest_dir, options) -> Result[List[Int]]
Archive.extract_zip(src, members, dest_dir, options) -> Result[List[Int]]
```

- `options` is `Archive.Options(timeout_ms, max_output_bytes)`; the defaults
  are 30000 and 268435456. `timeout_ms` is 1 to 86400000, `max_output_bytes`
  1 to 1073741824. The result holds each file's bytes in member order.
- `members` holds 1 to 256 safe relative paths; one leading `./` is optional.
  Absolute paths, drive letters, UNC shares, backslashes, colons, NUL bytes,
  `.`/`..` segments, exact and case-only repeats are rejected before anything
  is created. `dest_dir` is made private and must not exist; files are created
  never-overwriting with parents under the new base.
- Only regular files are written; a selected link, directory, device or sparse
  entry is an error. The whole container is scanned through the two zero end
  blocks, so a duplicate, a missing member or a bad checksum after a selected
  file still fails. A gzipped archive must hold exactly one member with its
  CRC and size verified and no trailing bytes. The source must be a stable
  caller-owned regular file (`File.lstat` cannot rule out a rename race).
- Fixed ceilings: raw TAR scan 1073741824 bytes, gzipped source 268435456
  compressed bytes, 8192 entries, 1024 name bytes, 65536 bytes of PAX and GNU
  extension data. USTAR with PAX `path`/`size` and GNU long names; other PAX
  records are ignored, sparse entries are refused. ZIP: source at most
  268435456 bytes over three forward-only passes (768 MiB of physical reads),
  8192 entries, 1024 name bytes; strict UTF-8 with flag 11 else pure ASCII.
  Selected payloads stream in their exact window with CRC32 and size checked;
  unselected payloads are skipped by size and offset only, never CRC-checked.
