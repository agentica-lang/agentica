## Extracts named regular files from TAR and ZIP archives.
##
## Import it with `import Archive from "std/archive"`. `extract_tar` copies one allowlist of regular files out of a
## plain TAR or a gzipped TAR (detected by the gzip magic) into a new private directory, and returns the byte counts
## in member order. `extract_zip` copies one allowlist of regular files out of a classic single-disk ZIP32 archive
## the same way. The only operations are those two: there is no extract-all, no glob, no listing and no ZIP writer.
## Every failure is an `error` result, never a halt; a partial destination is kept on error and is only usable when
## the call returns `ok`.
##
## The call validates the allowlist before touching the disk, creates the destination with `Dir.mkdir_private` (an
## existing path is an error, a missing parent is an error), then streams the archive in 64 KiB chunks (`File.chunks`,
## through `gunzip` for a gzipped one) without ever holding the whole file, the whole decompressed stream or a skipped
## entry in memory. It scans the whole container through the two zero end blocks and the zeros-only padding after them,
## so a duplicate, a missing member or a bad checksum after a selected file is still an error. A gzipped archive must
## hold exactly one gzip member with its CRC and size verified and no trailing bytes. Only regular files are written,
## each with `create_private` and parents made under the new base; links, devices and sparse entries are refused when
## selected and skipped otherwise. Names keep their archive spelling after one optional leading `./`, so `./lib.so` and
## `lib.so` are the same member; the root header `.` or `./` of an archive of `.` is allowed but never extracted.
## Absolute paths, drive letters, UNC shares, backslashes, colons, NUL bytes and `.` or `..` segments are rejected, as
## are two members that only differ in case. The source must be a stable caller-owned regular file: it is checked with
## `File.lstat`, which cannot promise that a rename race did not swap it afterwards.

import Zip from "std/internal/archive_zip"

# Fixed ceilings, documented on `extract_tar`.
CHUNK = 65536
HEADER_BYTES = 512
NAME_BYTES = 1024
MAX_ENTRIES = 8192
MAX_MEMBERS = 256
META_BYTES = 65536
SCAN_BYTES = 1073741824
INPUT_BYTES = 268435456
CLOSE_MS = 5000
INT_MAX = 9223372036854775807

# The gzip magic: 0x1F 0x8B.
GZIP_FIRST = 31
GZIP_SECOND = 139

# The bytes of "sparse", which no PAX key may hold.
SPARSE_KEY = [115, 112, 97, 114, 115, 101]

## The knobs of `extract_tar`. Every other limit is a fixed ceiling named in `extract_tar`.
export struct Options
  ## The whole call in milliseconds, 1 to 86400000. Defaults to 30000.
  timeout_ms: Int
  ## The largest total of extracted file bytes, 1 to 1073741824. Defaults to 268435456.
  max_output_bytes: Int
end

# One validated allowlist member: the canonical archive path and its segments under the new base.
struct Wanted
  path: String
  segments: List[String]
end

# One parsed header: the raw name bytes, the size and the type flag.
struct TarHeader
  name: List[Int]
  size: Int
  typeflag: Int
end

# The pending one-entry overrides from a local PAX header. The global PAX state lives in Ctx.
struct Local
  has_path: Bool
  path: List[Int]
  has_size: Bool
  size: Int
end

# Everything the scan loop carries besides the cursor.
struct Ctx
  dest: String
  deadline: Int
  max_output: Int
  wanted: List[Wanted]
  matched: List[Bool]
  counts: List[Int]
  extracted: Int
  entries: Int
  meta_used: Int
  local: Local
  gnu_name: List[Int]
  has_gnu_name: Bool
  global_path: List[Int]
  has_global_path: Bool
  global_size: Int
  has_global_size: Bool
  seen_fold: Map[String, Bool]
  seen_exact: Map[String, Bool]
end

# What the scan of the TAR stream waits for: a header block, the data of a PAX or GNU record, the data of an entry,
# the padding after it, or (after the two zero blocks) nothing but zeros.
enum Phase
  Header
  Meta
  Data
  Pad
  Trailer
end

# The state of the scan between two chunks of the TAR stream. `carry` holds the bytes the phase still needs more of
# (part of a header or of a record). `rest` is what the phase still takes; `size` is the whole record, entry or
# padding, for the truncation message, and `what` names it. A selected entry writes to `out`, its wanted `index`,
# under its case-folded name `fold`; an entry that is skipped has `out` "". `total` counts the bytes of the stream.
struct Scan
  ctx: Ctx
  carry: List[Int]
  phase: Phase
  zeros: Int
  rest: Int
  size: Int
  what: String
  typeflag: Int
  entry: Int
  out: String
  index: Int
  fold: String
  total: Int
end

## Returns the default options: a 30 s deadline and at most 256 MiB of extracted files.
export def options() -> Options
  return Options(timeout_ms: 30000, max_output_bytes: 268435456)
end

## Copies the allowlisted `members` out of the ZIP archive at `src` into `dest_dir` and returns each file's bytes in
## member order.
##
## `src` is a classic single-disk `.zip` file holding stored (method 0) and raw deflate (method 8) entries only:
## ZIP64, encryption, multi-disk images, split archives, self-extractors and other methods are refused. `members`
## holds 1 to 256 archive paths with the same safe-relative rules as `extract_tar`, `dest_dir` is created private
## and must not exist, and only regular files are written; a selected link, directory or device is an error. The
## reader makes three forward-only passes in 64 KiB reads without ever holding the file, so the source is at most
## 256 MiB and the passes together read at most 768 MiB of physical bytes. Fixed ceilings: 8192 entries, 1024 name
## bytes. Names are strict UTF-8 when flag 11 is set and pure ASCII otherwise; legacy CP437 bytes are refused,
## never misdecoded. Every local record is validated even after the selected files, so corruption past a selected
## file is still an error. Selected payloads stream within their exact compressed window with their CRC32 and
## uncompressed size verified; unselected payloads are skipped by size and offset only, never inflated or
## CRC-checked.
export def extract_zip(src: String, members: List[String], dest_dir: String, options: Options) -> Result[List[Int]]
  if options.timeout_ms <= 0 or options.timeout_ms > 86400000
    return error("archive: options.timeout_ms must be 1..86400000")
  end
  if options.max_output_bytes <= 0 or options.max_output_bytes > SCAN_BYTES
    return error("archive: options.max_output_bytes must be 1..1073741824")
  end
  return Zip.extract_zip(src, members, dest_dir, options.timeout_ms, options.max_output_bytes)
end

## Copies the allowlisted `members` out of the TAR archive at `src` into `dest_dir` and returns each file's bytes in
## member order.
##
## `src` is a plain `.tar` or a `.tar.gz` file. `members` holds 1 to 256 archive paths; each must be a safe relative
## path after one optional leading `./`, with no duplicates and no two entries that only differ in case. `dest_dir`
## is created private and must not exist. Fixed ceilings: the raw TAR scan is at most 1073741824 bytes, a gzipped
## source at most 268435456 compressed bytes, 8192 entries, 1024 name bytes and 65536 bytes of PAX and GNU extension
## data. Headers follow USTAR with PAX `path` and `size` records (local for one entry, global until replaced) and GNU
## long names; other PAX records are ignored, sparse entries are refused, and only `0`, NUL and `7` type flags count
## as regular files. A selected link, directory or device is an error, as are a missing member, a repeated member, a
## bad checksum, truncation, non-zero padding after the end, and any trailing bytes after the gzip member.
export def extract_tar(src: String, members: List[String], dest_dir: String, options: Options) -> Result[List[Int]]
  if options.timeout_ms <= 0 or options.timeout_ms > 86400000
    return error("archive: options.timeout_ms must be 1..86400000")
  end
  if options.max_output_bytes <= 0 or options.max_output_bytes > SCAN_BYTES
    return error("archive: options.max_output_bytes must be 1..1073741824")
  end
  now = Time.monotonic_ms()
  if now > INT_MAX - options.timeout_ms
    return error("archive: the clock is too far ahead for the timeout")
  end
  deadline = now + options.timeout_ms
  wanted = try validate_members(members)
  # The destination in the spelling the host join produces: on Windows Path.join turns every `\` into a `/`,
  # while a caller may hold `\` (a cache root from the OS does), and the under-destination guard compares the joined
  # output with this folder literally. Without this a valid destination looks like an escape on Windows.
  joined = try join_one([dest_dir])
  dest = strip_slashes(joined)
  if dest == ""
    return error("archive: destination must not be empty")
  end
  info = try stat_src(src, deadline)
  if info.kind != "file"
    return error("archive: source is not a regular file: #{src}")
  end
  try make_dest(dest, deadline)
  first = try read_first(src, deadline)
  if first.size == 0
    return error("archive: #{src} is empty, not a TAR archive")
  end
  gzip = false
  if first.size >= 2
    gzip = first[0] == GZIP_FIRST and first[1] == GZIP_SECOND
  end
  ctx = Ctx(
    dest: dest,
    deadline: deadline,
    max_output: options.max_output_bytes,
    wanted: wanted,
    matched: List.repeat(false, wanted.size),
    counts: List.repeat(0, wanted.size),
    extracted: 0,
    entries: 0,
    meta_used: 0,
    local: Local(has_path: false, path: [], has_size: false, size: 0),
    gnu_name: [],
    has_gnu_name: false,
    global_path: [],
    has_global_path: false,
    global_size: 0,
    has_global_size: false,
    seen_fold: {},
    seen_exact: {},
  )
  scan = Scan(
    ctx: ctx,
    carry: [],
    phase: Phase.Header,
    zeros: 0,
    rest: 0,
    size: 0,
    what: "",
    typeflag: 0,
    entry: 0,
    out: "",
    index: -1,
    fold: "",
    total: 0,
  )
  outcome = scan_all(src, gzip, scan, members)
  if !outcome.ok?
    return error(Result.message(outcome))
  end
  return outcome
end

def smaller(a: Int, b: Int) -> Int
  if a < b
    return a
  end
  return b
end

def time_left(deadline: Int) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return error("archive: operation timed out")
  end
  return ok(left)
end

# The budget of a cleanup close: the remaining deadline, capped, and never zero or negative.
def close_budget(deadline: Int) -> Int
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return CLOSE_MS
  end
  return smaller(left, CLOSE_MS)
end

def close_file(handle: FileHandle, budget: Int) -> Void
  case File.close(handle, budget)
    ok(_) -> return
    error(_) -> return
  end
end

def stat_src(src: String, deadline: Int) -> Result[FileInfo]
  case File.lstat(src, try time_left(deadline))
    ok(found) -> return ok(found)
    error(message) -> return error("archive: cannot use #{src}: #{message}")
  end
end

# The first bytes of the source, to tell a gzipped archive by its magic.
def read_first(src: String, deadline: Int) -> Result[List[Int]]
  case File.chunks(src, 2, try time_left(deadline)).first(1)
    ok(chunks) ->
      if chunks.size == 0
        return ok([])
      end
      return ok(chunks[0])
    error(message) -> return error("archive: cannot open #{src}: #{message}")
  end
end

def make_dest(dest: String, deadline: Int) -> Result[Void]
  case Dir.mkdir_private(dest, try time_left(deadline))
    ok(_) -> return ok()
    error(message) -> return error("archive: cannot create #{dest}: #{message}")
  end
end

def strip_slashes(path: String) -> String
  out = path
  while String.length(out) > 1
    if !String.ends_with?(out, "/")
      break
    end
    out = String.slice(out, 0, String.length(out) - 1)
  end
  return out
end

def is_zero_block(block: List[Int]) -> Bool
  stop = HEADER_BYTES - 1
  for i in 0..stop
    if block[i] != 0
      return false
    end
  end
  return true
end

def parse_octal(block: List[Int], offset: Int, length: Int, what: String, entry: Int) -> Result[Int]
  value = 0
  seen = false
  ended = false
  stop = length - 1
  for i in 0..stop
    b = block[offset + i]
    if b == 0 or b == 32
      if seen
        ended = true
      end
    else
      if ended
        return error("archive: bad octal #{what} at entry #{entry}")
      end
      if b < 48 or b > 55
        return error("archive: bad octal #{what} at entry #{entry}")
      end
      d = b - 48
      if value > (INT_MAX - d) / 8
        return error("archive: #{what} overflows at entry #{entry}")
      end
      value = value * 8 + d
      seen = true
    end
  end
  return ok(value)
end

def parse_decimal(text: List[Int], what: String, entry: Int) -> Result[Int]
  if text.size == 0
    return error("archive: bad decimal #{what} at entry #{entry}")
  end
  value = 0
  stop = text.size - 1
  for i in 0..stop
    b = text[i]
    if b < 48 or b > 57
      return error("archive: bad decimal #{what} at entry #{entry}")
    end
    d = b - 48
    if value > (INT_MAX - d) / 10
      return error("archive: #{what} overflows at entry #{entry}")
    end
    value = value * 10 + d
  end
  return ok(value)
end

def trim_nul(bytes: List[Int]) -> List[Int]
  if bytes.size == 0
    return []
  end
  stop = bytes.size - 1
  for i in 0..stop
    if bytes[i] == 0
      return List.take(bytes, i)
    end
  end
  return bytes
end

def slice_range(bytes: List[Int], from: Int, to: Int) -> List[Int]
  return List.take(List.drop(bytes, from), to - from)
end

def read_header(block: List[Int], entry: Int) -> Result[TarHeader]
  stored = try parse_octal(block, 148, 8, "checksum", entry)
  total = 0
  stop = HEADER_BYTES - 1
  for i in 0..stop
    if i >= 148 and i < 156
      total += 32
    else
      total += block[i]
    end
  end
  if total != stored
    return error("archive: bad header checksum at entry #{entry}")
  end
  if block[124] >= 128
    return error("archive: unsupported base-256 size at entry #{entry}")
  end
  size = try parse_octal(block, 124, 12, "size", entry)
  name_field = trim_nul(slice_range(block, 0, 100))
  prefix = trim_nul(slice_range(block, 345, 500))
  ustar = block[257] == 117 and block[258] == 115 and block[259] == 116 and block[260] == 97 and block[261] == 114
  if !ustar and prefix.size > 0
    return error("archive: unsupported archive variant at entry #{entry}")
  end
  full = name_field
  if prefix.size > 0
    full = List.concat(List.concat(prefix, [47]), name_field)
  end
  return ok(TarHeader(name: full, size: size, typeflag: block[156]))
end

# True when `hay` holds `needle` anywhere.
def bytes_have(hay: List[Int], needle: List[Int]) -> Bool
  if needle.size == 0
    return true
  end
  if hay.size < needle.size
    return false
  end
  stop = hay.size - needle.size
  inner = needle.size - 1
  for i in 0..stop
    hit = true
    for j in 0..inner
      if hay[i + j] != needle[j]
        hit = false
        break
      end
    end
    if hit
      return true
    end
  end
  return false
end

# Applies one PAX record to the local or the global overrides.
def apply_record(ctx: Ctx, key: List[Int], value: List[Int], entry: Int, is_global: Bool) -> Result[Ctx]
  if bytes_have(key, SPARSE_KEY)
    return error("archive: sparse entries are not supported at entry #{entry}")
  end
  key_text = try key_text_of(key, entry)
  if key_text == "path"
    if value.size > NAME_BYTES
      return error("archive: entry name is too long at entry #{entry}")
    end
    if is_global
      return ok(ctx.with(has_global_path: true, global_path: value))
    end
    local = ctx.local
    return ok(ctx.with(local: local.with(has_path: true, path: value)))
  end
  if key_text == "size"
    size = try parse_decimal(value, "PAX size", entry)
    if is_global
      return ok(ctx.with(has_global_size: true, global_size: size))
    end
    local = ctx.local
    return ok(ctx.with(local: local.with(has_size: true, size: size)))
  end
  return ok(ctx)
end

# Parses PAX records, replacing the local or the global overrides. Other keys are ignored.
def parse_pax(data: List[Int], entry: Int, is_global: Bool, ctx: Ctx) -> Result[Ctx]
  if is_global
    ctx = ctx.with(has_global_path: false, global_path: [], has_global_size: false, global_size: 0)
  else
    ctx = ctx.with(local: Local(has_path: false, path: [], has_size: false, size: 0))
  end
  pos = 0
  while pos < data.size
    j = pos
    while j < data.size
      if data[j] == 32
        break
      end
      j += 1
    end
    if j == pos or j >= data.size
      return error("archive: bad PAX record at entry #{entry}")
    end
    length = try parse_decimal(slice_range(data, pos, j), "PAX length", entry)
    if length <= j - pos + 1 or pos + length > data.size
      return error("archive: bad PAX record at entry #{entry}")
    end
    if data[pos + length - 1] != 10
      return error("archive: bad PAX record at entry #{entry}")
    end
    body_end = pos + length - 1
    eq = j + 1
    while eq < body_end
      if data[eq] == 61
        break
      end
      eq += 1
    end
    if eq >= body_end
      return error("archive: bad PAX record at entry #{entry}")
    end
    key = slice_range(data, j + 1, eq)
    if key.size == 0
      return error("archive: bad PAX record at entry #{entry}")
    end
    ctx = try apply_record(ctx, key, slice_range(data, eq + 1, body_end), entry, is_global)
    pos += length
  end
  return ok(ctx)
end

# Checks one relative path after its leading `./` is gone: no absolute, drive, UNC, backslash, colon or NUL content
# and no empty, `.` or `..` segments. `name` and `suffix` shape the error.
def check_relative(path: String, name: String, suffix: String) -> Result[String]
  if String.starts_with?(path, "/")
    return error("archive: #{name} is absolute#{suffix}")
  end
  for b in String.to_bytes(path)
    if b == 0
      return error("archive: #{name} holds a NUL byte#{suffix}")
    end
    if b == 92 or b == 58
      return error("archive: #{name} holds a portable separator#{suffix}")
    end
  end
  if String.length(path) >= 2
    if String.slice(path, 1, 1) == ":"
      return error("archive: #{name} holds a drive letter#{suffix}")
    end
  end
  if String.starts_with?(path, "\\\\")
    return error("archive: #{name} is a UNC path#{suffix}")
  end
  for seg in String.split(path, "/")
    if seg == "" or seg == "." or seg == ".."
      return error("archive: #{name} is not a safe relative path#{suffix}")
    end
  end
  return ok(path)
end

# Validates one allowlist member: nonempty, short, and a safe relative path after one optional leading `./`.
def normalize_selector(text: String) -> Result[String]
  if text == ""
    return error("archive: a member must not be empty")
  end
  if String.to_bytes(text).size > NAME_BYTES
    return error("archive: member is too long: #{text}")
  end
  path = text
  if String.starts_with?(path, "./")
    path = String.slice(path, 2, String.length(path) - 2)
  end
  if path == "" or path == "."
    return error("archive: a member must name a file, not the root: #{text}")
  end
  return check_relative(path, "member #{text}", "")
end

# Decodes entry name bytes for matching: one leading `./` and any trailing `/` characters are removed, and anything
# undecodable, over-long or empty becomes `""`, which never matches a selector. Unmatched entries skip on this alone;
# only a matched entry faces the strict `check_relative` of `consume_entry`.
def match_name_of(raw: List[Int]) -> String
  if raw.size == 0 or raw.size > NAME_BYTES
    return ""
  end
  stop = raw.size - 1
  for i in 0..stop
    if raw[i] == 0
      return ""
    end
  end
  path = decode_or_empty(raw)
  if String.starts_with?(path, "./")
    path = String.slice(path, 2, String.length(path) - 2)
  end
  while String.length(path) > 0 and String.ends_with?(path, "/")
    path = String.slice(path, 0, String.length(path) - 1)
  end
  return path
end

# Validates the whole allowlist: 1 to 256 safe members, no exact, normalized or case-only repeats.
def validate_members(members: List[String]) -> Result[List[Wanted]]
  if members.size == 0 or members.size > MAX_MEMBERS
    return error("archive: members must select 1..256 files")
  end
  wanted: List[Wanted] = []
  for text in members
    canon = try normalize_selector(text)
    for seen in wanted
      if seen.path == canon
        return error("archive: members select the same file twice: #{canon}")
      end
      if String.downcase(seen.path) == String.downcase(canon)
        return error("archive: members collide on a case-insensitive system: #{seen.path} and #{canon}")
      end
    end
    wanted = List.append(wanted, Wanted(path: canon, segments: String.split(canon, "/")))
  end
  return ok(wanted)
end

def find_match(wanted: List[Wanted], canon: String) -> Int
  stop = wanted.size - 1
  for i in 0..stop
    item = wanted[i]
    if item.path == canon
      return i
    end
  end
  return -1
end

def key_text_of(key: List[Int], entry: Int) -> Result[String]
  case String.from_bytes(key)
    ok(text) -> return ok(text)
    error(_) -> return error("archive: bad PAX key at entry #{entry}")
  end
end

def decode_or_empty(raw: List[Int]) -> String
  case String.from_bytes(raw)
    ok(decoded) -> return decoded
    error(_) -> return ""
  end
end

def join_one(parts: List[String]) -> Result[String]
  case Path.join(parts)
    ok(joined) -> return ok(joined)
    error(_) -> return error("archive: cannot join a path")
  end
end

# True when `out` is the destination itself or lies directly below it. Either path separator counts: `Path.join`
# uses the host one, and the joined segments themselves never hold a separator.
def stays_under(out: String, dest: String) -> Bool
  if out == dest
    return true
  end
  if String.starts_with?(out, "#{dest}/")
    return true
  end
  return String.starts_with?(out, back_join(dest))
end

def back_join(dest: String) -> String
  return "#{dest}\\"
end

def join_under(dest: String, segments: List[String]) -> Result[String]
  out = try join_one(List.concat([dest], segments))
  if !stays_under(out, dest)
    return error("archive: selected path escapes the destination")
  end
  return ok(out)
end

# Creates the parents of a selected file under the new base, refusing case-only collisions portably.
def make_parents(ctx: Ctx, segments: List[String], deadline: Int) -> Result[Ctx]
  if segments.size <= 1
    return ok(ctx)
  end
  parts: List[String] = [ctx.dest]
  stop = segments.size - 2
  for k in 0..stop
    parts = List.append(parts, segments[k])
    dir = try join_one(parts)
    if !stays_under(dir, ctx.dest)
      return error("archive: selected path escapes the destination")
    end
    fold = String.downcase(dir)
    if Map.has_key?(ctx.seen_fold, fold) and !Map.has_key?(ctx.seen_exact, dir)
      return error("archive: selected files collide on a case-insensitive system: #{dir}")
    end
    if !Map.has_key?(ctx.seen_exact, dir)
      case Dir.mkdir(dir, try time_left(deadline))
        ok(_) ->
          ctx = ctx.with(
            seen_fold: Map.put(ctx.seen_fold, fold, true), seen_exact: Map.put(ctx.seen_exact, dir, true),
          )
        error(message) -> return error("archive: cannot create a parent directory: #{message}")
      end
    end
  end
  return ok(ctx)
end

# Creates one selected file empty, with `create_private`: its data is appended chunk by chunk as it streams in, so no
# handle stays open between two chunks and every error path leaves nothing open.
def create_out(out: String, deadline: Int) -> Result[Void]
  left = try time_left(deadline)
  case File.open(out, "create_private", left)
    ok(handle) ->
      case File.close(handle, close_budget(deadline))
        ok(_) -> return ok()
        error(message) -> return error("archive: cannot finish #{out}: #{message}")
      end
    error(message) -> return error("archive: cannot create #{out}: #{message}")
  end
end

# Appends one piece of a selected file's data.
def append_out(out: String, piece: List[Int], deadline: Int) -> Result[Void]
  left = try time_left(deadline)
  case File.open(out, "append", left)
    ok(handle) ->
      case File.write_bytes(handle, piece, left)
        ok(_) ->
          case File.close(handle, close_budget(deadline))
            ok(_) -> return ok()
            error(message) -> return error("archive: cannot finish #{out}: #{message}")
          end
        error(message) ->
          close_file(handle, close_budget(deadline))
          return error("archive: cannot write #{out}: #{message}")
      end
    error(message) -> return error("archive: cannot write #{out}: #{message}")
  end
end

# Scans the whole TAR stream (the file, or its one gzip member) through the end blocks and the zero padding, writing
# every selected file on the way, then names a member the archive never held.
def scan_all(src: String, gzip: Bool, scan: Scan, members: List[String]) -> Result[List[Int]]
  deadline = scan.ctx.deadline
  stream = File.chunks(src, CHUNK, try time_left(deadline))
  if gzip
    stream = stream.with_index do |chunk: List[Int], index: Int| try within_input(chunk, index) end
      .gunzip(SCAN_BYTES)
  end
  outcome = stream.reduce(scan) do |sc: Scan, chunk: List[Int]| try feed(sc, chunk, gzip) end
  case outcome
    ok(done) ->
      try check_end(done)
      try check_missing(done.ctx, members)
      return ok(done.ctx.counts)
    error(message) -> return error(stream_error(message, src))
  end
end

# A compressed chunk passes while the file bytes read so far stay within INPUT_BYTES: File.chunks gives CHUNK bytes
# each, the last one fewer.
def within_input(chunk: List[Int], index: Int) -> Result[List[Int]]
  if index * CHUNK + chunk.size > INPUT_BYTES
    return error("archive: compressed input exceeds 268435456 bytes")
  end
  return ok(chunk)
end

# The error of the stream as std/archive words it: its own errors as they are, a refusal of the gzip member, or a
# failed read of the source. The zlib texts matched here are the ones vm/zlib.c gives (agc_zstep_next): keep them in
# step.
def stream_error(message: String, src: String) -> String
  if String.starts_with?(message, "archive: ")
    return message
  end
  if message == "zlib: trailing bytes after stream end"
    return "archive: trailing bytes after the gzip member"
  end
  if message == "zlib: truncated stream"
    return "archive: gzip stream is truncated"
  end
  if message == "zlib: output exceeds max_bytes"
    return "archive: decompressed input exceeds 1073741824 bytes"
  end
  if String.starts_with?(message, "zlib: ")
    return "archive: gzip input is invalid: #{message}"
  end
  return "archive: cannot read #{src}: #{message}"
end

# Takes one chunk of the TAR stream: each phase takes what it needs of the bytes held so far, and what a phase still
# needs more of waits in `carry` for the next chunk.
def feed(sc: Scan, chunk: List[Int], gzip: Bool) -> Result[Scan]
  if Time.monotonic_ms() >= sc.ctx.deadline
    return error("archive: operation timed out")
  end
  total = sc.total + chunk.size
  if !gzip and total > SCAN_BYTES
    return error("archive: raw input exceeds 1073741824 bytes")
  end
  buf = chunk
  if sc.carry.size > 0
    buf = List.concat(sc.carry, chunk)
  end
  sc = sc.with(carry: [], total: total)
  while buf.size > 0
    case sc.phase
      Phase.Header ->
        if buf.size < HEADER_BYTES
          return ok(sc.with(carry: buf))
        end
        sc = try take_header(sc, List.take(buf, HEADER_BYTES))
        buf = List.drop(buf, HEADER_BYTES)
      Phase.Meta ->
        if buf.size < sc.rest
          return ok(sc.with(carry: buf))
        end
        n = sc.rest
        sc = try take_meta(sc, List.take(buf, n))
        buf = List.drop(buf, n)
      Phase.Data ->
        n = smaller(sc.rest, buf.size)
        sc = try take_data(sc, List.take(buf, n))
        buf = List.drop(buf, n)
      Phase.Pad ->
        n = smaller(sc.rest, buf.size)
        sc = after_pad(sc.with(rest: sc.rest - n))
        buf = List.drop(buf, n)
      Phase.Trailer ->
        counts = List.tally(buf)
        if Map.size(counts) != 1 or !Map.has_key?(counts, 0)
          return error("archive: non-zero padding after the archive end")
        end
        buf = []
    end
  end
  return ok(sc)
end

# One header block: a zero block counts toward the end, any other one starts an entry.
def take_header(sc: Scan, block: List[Int]) -> Result[Scan]
  if is_zero_block(block)
    if sc.zeros + 1 == 2
      return ok(sc.with(zeros: 2, phase: Phase.Trailer))
    end
    return ok(sc.with(zeros: sc.zeros + 1))
  end
  ctx = sc.ctx
  if ctx.entries >= MAX_ENTRIES
    return error("archive: too many entries, past 8192")
  end
  entry = ctx.entries + 1
  sc = sc.with(zeros: 0, entry: entry, ctx: ctx.with(entries: entry))
  return start_entry(sc, try read_header(block, entry))
end

# Starts one entry: a PAX or GNU record waits for its data, a selected regular file is created and its data
# streamed into it, any other entry is skipped.
def start_entry(sc: Scan, header: TarHeader) -> Result[Scan]
  ctx = sc.ctx
  entry = sc.entry
  if header.typeflag == 120 or header.typeflag == 103 or header.typeflag == 76 or header.typeflag == 75
    if header.size > META_BYTES - ctx.meta_used
      return error("archive: metadata exceeds 65536 bytes at entry #{entry}")
    end
    what = "GNU long name data"
    if header.typeflag == 120 or header.typeflag == 103
      what = "PAX data"
    end
    sc = sc.with(phase: Phase.Meta, rest: header.size, size: header.size, what: what, typeflag: header.typeflag)
    if header.size == 0
      return take_meta(sc, [])
    end
    return ok(sc)
  end
  raw = header.name
  if ctx.local.has_path
    raw = ctx.local.path
  else
    if ctx.has_gnu_name
      raw = ctx.gnu_name
    else
      if ctx.has_global_path
        raw = ctx.global_path
      end
    end
  end
  size = header.size
  if ctx.local.has_size
    size = ctx.local.size
  else
    if ctx.has_global_size
      size = ctx.global_size
    end
  end
  ctx = ctx.with(
    local: Local(has_path: false, path: [], has_size: false, size: 0), has_gnu_name: false, gnu_name: [],
  )
  canon = match_name_of(raw)
  if size > SCAN_BYTES
    return error("archive: entry size exceeds 1073741824 bytes at entry #{entry}")
  end
  regular = header.typeflag == 48 or header.typeflag == 0 or header.typeflag == 55
  index = -1
  if canon != ""
    index = find_match(ctx.wanted, canon)
  end
  sc = sc.with(ctx: ctx, phase: Phase.Data, rest: size, size: size, what: "entry data", out: "", index: -1)
  if index >= 0
    try check_relative(canon, "entry name", " at entry #{entry}")
    if ctx.matched[index]
      return error("archive: the same archive holds #{canon} twice")
    end
    if !regular
      return error("archive: member is not a regular file: #{canon}")
    end
    sc = try open_selected(sc, index, size)
  end
  if size == 0
    return end_data(sc)
  end
  return ok(sc)
end

# Checks the place of one selected file and creates it under the new base, within both output caps.
def open_selected(sc: Scan, index: Int, size: Int) -> Result[Scan]
  ctx = sc.ctx
  item = ctx.wanted[index]
  out = try join_under(ctx.dest, item.segments)
  fold = String.downcase(out)
  if Map.has_key?(ctx.seen_fold, fold)
    return error("archive: selected files collide on a case-insensitive system: #{out}")
  end
  ctx = try make_parents(ctx, item.segments, ctx.deadline)
  if size > ctx.max_output or ctx.extracted + size > ctx.max_output
    return error("archive: output exceeds #{ctx.max_output} bytes")
  end
  try create_out(out, ctx.deadline)
  return ok(sc.with(ctx: ctx, out: out, index: index, fold: fold, what: "file data of #{item.path}"))
end

# The data of a PAX or GNU record, then its padding.
def take_meta(sc: Scan, data: List[Int]) -> Result[Scan]
  ctx = sc.ctx.with(meta_used: sc.ctx.meta_used + sc.size)
  if sc.typeflag == 120 or sc.typeflag == 103
    ctx = try parse_pax(data, sc.entry, sc.typeflag == 103, ctx)
  else
    if sc.typeflag == 76
      trimmed = trim_nul(data)
      if trimmed.size > NAME_BYTES
        return error("archive: entry name is too long at entry #{sc.entry}")
      end
      ctx = ctx.with(has_gnu_name: true, gnu_name: trimmed)
    end
  end
  return ok(start_pad(sc.with(ctx: ctx), sc.size))
end

# One piece of an entry's data: written when the entry is selected, dropped when not.
def take_data(sc: Scan, piece: List[Int]) -> Result[Scan]
  if sc.out != ""
    try append_out(sc.out, piece, sc.ctx.deadline)
  end
  sc = sc.with(rest: sc.rest - piece.size)
  if sc.rest == 0
    return end_data(sc)
  end
  return ok(sc)
end

# The end of an entry's data: a selected file counts, then the padding follows.
def end_data(sc: Scan) -> Result[Scan]
  if sc.out != ""
    ctx = sc.ctx
    ctx = ctx.with(
      matched: List.set(ctx.matched, sc.index, true),
      counts: List.set(ctx.counts, sc.index, sc.size),
      extracted: ctx.extracted + sc.size,
      seen_fold: Map.put(ctx.seen_fold, sc.fold, true),
      seen_exact: Map.put(ctx.seen_exact, sc.out, true),
    )
    sc = sc.with(ctx: ctx, out: "", index: -1)
  end
  return ok(start_pad(sc, sc.size))
end

# The zero padding after `size` data bytes up to the next 512-byte block.
def start_pad(sc: Scan, size: Int) -> Scan
  pad = (HEADER_BYTES - size % HEADER_BYTES) % HEADER_BYTES
  return after_pad(sc.with(phase: Phase.Pad, rest: pad, size: pad, what: "entry padding"))
end

def after_pad(sc: Scan) -> Scan
  if sc.rest == 0
    return sc.with(phase: Phase.Header, size: 0)
  end
  return sc
end

# The stream ended: only the zeros after the two end blocks may end it.
def check_end(sc: Scan) -> Result[Void]
  case sc.phase
    Phase.Trailer -> return ok()
    Phase.Header ->
      if sc.carry.size == 0
        return error("archive: truncated archive, missing the two zero end blocks")
      end
      return error("archive: truncated TAR data, needed 512 bytes for a header")
    Phase.Data ->
      # The bytes the reader of a whole file wanted when the data ran out: what was left of its CHUNK-sized piece.
      needed = smaller(sc.size - (sc.size - sc.rest) / CHUNK * CHUNK, CHUNK)
      return error("archive: truncated TAR data, needed #{needed} bytes for #{sc.what}")
    Phase.Meta -> return error("archive: truncated TAR data, needed #{sc.size} bytes for #{sc.what}")
    Phase.Pad -> return error("archive: truncated TAR data, needed #{sc.size} bytes for #{sc.what}")
  end
end

# Names every selected member that the archive never held.
def check_missing(ctx: Ctx, members: List[String]) -> Result[Void]
  stop = ctx.wanted.size - 1
  for i in 0..stop
    if !ctx.matched[i]
      return error("archive: member not found: #{members[i]}")
    end
  end
  return ok()
end
