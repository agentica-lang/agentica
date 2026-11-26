# Archive (`std/archive`)

`import Archive from "std/archive"`. Copies an explicit allowlist of regular
files out of a plain `.tar`, gzipped `.tar.gz`, or classic single-disk `.zip`
(stored and raw deflate only) into a new private directory. Every failure is
an `error`; none halts.

```text
Archive.extract_tar(src, members, dest_dir, options = Archive.Options()) -> Result[List[Int]]
Archive.extract_zip(src, members, dest_dir, options = Archive.Options()) -> Result[List[Int]]
```

- `options` is `Archive.Options(timeout_ms: Int = 30000,
  max_output_bytes: Int = 268435456, keep_mode: Bool = false)`,
  `Archive.Options()` by default. `timeout_ms` is 1 to 86400000,
  `max_output_bytes` 1 to 1073741824. The result holds each file's bytes in
  member order.
- `keep_mode: true` (`extract_tar` only; `extract_zip` refuses it with an
  `argument` error) gives each file its TAR header's permission bits masked
  by `0o755` (no setuid, setgid or sticky, no group or other write bit);
  without it every file is private (`0o600`). A selected entry's mode field
  must be octal text.
- `members` holds 1 to 256 safe relative paths; one leading `./` is optional.
  Absolute paths, drive letters, UNC shares, backslashes, colons, NUL bytes,
  `.`/`..` segments, exact and case-only repeats are rejected before anything
  is created. `dest_dir` is made private and must not exist; files are created
  never-overwriting with parents under the new base.
- Only regular files are written; a selected link, directory, device or sparse
  entry is an error. The whole container is scanned, so a duplicate, a missing
  member or a bad checksum after a selected file still fails. A gzipped
  archive is read through `gunzip` (every member): the TAR must still end at
  its zero blocks, and no byte may follow the last member. The source must
  be a stable caller-owned regular file.
- Fixed ceilings: 8192 entries, 1024 name bytes, a 256 MiB compressed source.
  USTAR with PAX `path`/`size` and GNU long names; other PAX records are
  ignored. Unselected ZIP payloads are skipped, never CRC-checked.
