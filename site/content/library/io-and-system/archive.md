---
title: Archive
weight: 8
description: The Archive module, which extracts named files from TAR and ZIP archives.
---

`Archive` copies an explicit allowlist of regular files out of a TAR or ZIP archive into a new private directory. The only operations are the two extractors: there is no extract-all, no glob, no listing and no ZIP writer.

```text
Archive.options() -> Archive.Options
Archive.extract_tar(src: String, members: List[String], dest_dir: String, options: Archive.Options) -> Result[List[Int]]
Archive.extract_zip(src: String, members: List[String], dest_dir: String, options: Archive.Options) -> Result[List[Int]]
```

`extract_tar` reads a plain `.tar` or a gzipped `.tar.gz` (picked by the gzip magic), writes each member under `dest_dir`, and returns the byte counts in member order. `members` holds 1 to 256 archive paths; one leading `./` is optional, so `./lib.so` and `lib.so` are the same member. Every failure is an `error` and never a halt; a partial destination is kept on error and is only usable when the call returns `ok`.

```agentica {mode="check"}
import Archive from "std/archive"

def main() -> Void
  opts = Archive.options()
  case Archive.extract_tar("ffi.tar.gz", ["libssl.so", "include/ssl.h"], "vendor", opts)
    ok(counts) -> puts("wrote #{counts}")
    error(message) -> IO.warn("cannot unpack: #{message}")
  end
end
```

- `Archive.options()` is a 30 s deadline with at most 268435456 extracted bytes; `timeout_ms` is 1 to 86400000 and `max_output_bytes` is 1 to 1073741824.
- The destination is created private and must not exist; each file is created never-overwriting, with parents made under the new base. Only regular files are written: links, directories, devices and sparse entries are refused when selected and skipped otherwise.
- Names keep their archive spelling: absolute paths, drive letters, UNC shares, backslashes, colons, NUL bytes and `.` or `..` segments are rejected, as are two members that only differ in case. The call scans the whole container through the two zero end blocks, so a duplicate, a missing member or a bad checksum after a selected file is still an error.
- Fixed ceilings: the raw TAR scan is at most 1073741824 bytes, a gzipped source at most 268435456 compressed bytes, 8192 entries, 1024 name bytes and 65536 bytes of PAX and GNU extension data. Headers follow USTAR with PAX `path` and `size` records and GNU long names; other PAX records are ignored and sparse entries are refused.
- A gzipped archive must hold exactly one gzip member with its CRC and size verified and no trailing bytes. The source must be a stable caller-owned regular file: it is checked with `File.lstat`, which cannot promise that a rename race did not swap it afterwards.
- `extract_zip` reads a classic single-disk `.zip` with stored (method 0) and raw deflate (method 8) entries only: ZIP64, encryption, multi-disk images, split archives, self-extractors and other methods are refused. The reader makes three forward-only passes in 64 KiB reads, so the source is at most 268435456 bytes and the passes together read at most 768 MiB of physical bytes. Names are strict UTF-8 when flag 11 is set and pure ASCII otherwise; legacy CP437 bytes are refused. Every local record is validated even after the selected files. Selected payloads stream within their exact compressed window with their CRC32 and uncompressed size verified; unselected payloads are skipped by size and offset only, never inflated or CRC-checked.
