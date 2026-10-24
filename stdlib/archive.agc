## Extracts named regular files from a TAR archive.
##
## Import it with `import Archive from "std/archive"`. `extract_tar` copies one allowlist of regular files out of a
## plain TAR or a gzipped TAR (detected by the gzip magic) into a new private directory, and returns the byte counts
## in member order. It is the only operation: there is no extract-all, no glob, no listing and no ZIP. Every failure
## is an `error` result, never a halt; a partial destination is kept on error and is only usable when the call
## returns `ok`.
##
## The call validates the allowlist before touching the disk, creates the destination with `Dir.mkdir_private` (an
## existing path is an error, a missing parent is an error), then streams the archive in 64 KiB reads without ever
## holding the whole file, the whole decompressed stream or a skipped entry in memory. It scans the whole container
## through the two zero end blocks and the zeros-only padding after them, so a duplicate, a missing member or a bad
## checksum after a selected file is still an error. A gzipped archive must hold exactly one gzip member with its CRC
## and size verified and no trailing bytes. Only regular files are written, each with `create_private` and parents
## made under the new base; links, devices and sparse entries are refused when selected and skipped otherwise. Names
## keep their archive spelling after one optional leading `./`, so `./lib.so` and `lib.so` are the same member; the
## root header `.` or `./` of an archive of `.` is allowed but never extracted. Absolute paths, drive letters, UNC
## shares, backslashes, colons, NUL bytes and `.` or `..` segments are rejected, as are two members that only differ
## in case. The source must be a stable caller-owned regular file: it is checked with `File.lstat`, which cannot
## promise that a rename race did not swap it afterwards.

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

# The compressed side of a gzipped archive: the file and the streaming decoder.
struct GzipInput
  handle: FileHandle
  dec: ZlibDecoder
end

# The input handles. The top-level call owns this value, so every error path below it can close the handles.
enum Input
  Raw(FileHandle)
  Gzip(GzipInput)
end

# The pure half of the read state: buffered output bytes, unfed compressed bytes, and the accounting of the caps.
struct Cursor
  carry: List[Int]
  pending: List[Int]
  raw_read: Int
  out_total: Int
  file_eof: Bool
  stream_done: Bool
end

# The moved cursor with the bytes a take produced.
struct TakeOut
  cursor: Cursor
  bytes: List[Int]
end

# The moved cursor with one 512-byte header, or the clean end of the stream.
struct BlockOut
  cursor: Cursor
  done: Bool
  block: List[Int]
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

# The moved cursor with the moved scan context after one entry.
struct EntryOut
  cursor: Cursor
  ctx: Ctx
end

# The moved cursor with the moved scan context after one selected file.
struct WriteOut
  cursor: Cursor
  ctx: Ctx
end

## Returns the default options: a 30 s deadline and at most 256 MiB of extracted files.
export def options() -> Options
  return Options(timeout_ms: 30000, max_output_bytes: 268435456)
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
  dest = strip_slashes(dest_dir)
  if dest == ""
    return error("archive: destination must not be empty")
  end
  info = try stat_src(src, deadline)
  if info.kind != "file"
    return error("archive: source is not a regular file: #{src}")
  end
  try make_dest(dest, deadline)
  handle = try open_src(src, deadline)
  first = try read_first(handle, deadline, src)
  if first.size == 0
    close_file(handle, close_budget(deadline))
    return error("archive: #{src} is empty, not a TAR archive")
  end
  gzip = false
  if first.size >= 2
    gzip = first[0] == GZIP_FIRST and first[1] == GZIP_SECOND
  end
  input: Input = Input.Raw(handle)
  cur = Cursor(
    carry: first, pending: [], raw_read: first.size, out_total: first.size, file_eof: false, stream_done: false,
  )
  if gzip
    dec = try start_decoder(handle, deadline)
    input = Input.Gzip(GzipInput(handle: handle, dec: dec))
    cur = Cursor(carry: [], pending: first, raw_read: first.size, out_total: 0, file_eof: false, stream_done: false)
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
  outcome = scan_all(cur, input, ctx, members, deadline, src)
  close_input(input, deadline)
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

def close_input(input: Input, deadline: Int) -> Void
  budget = close_budget(deadline)
  case input
    Input.Raw(handle) -> close_file(handle, budget)
    Input.Gzip(g) ->
      close_file(g.handle, budget)
      case Zlib.decoder_close(g.dec)
        ok(_) -> return
        error(_) -> return
      end
  end
end

def stat_src(src: String, deadline: Int) -> Result[FileInfo]
  case File.lstat(src, try time_left(deadline))
    ok(found) -> return ok(found)
    error(message) -> return error("archive: cannot use #{src}: #{message}")
  end
end

def open_src(src: String, deadline: Int) -> Result[FileHandle]
  case File.open(src, "read", try time_left(deadline))
    ok(opened) -> return ok(opened)
    error(message) -> return error("archive: cannot open #{src}: #{message}")
  end
end

def read_first(handle: FileHandle, deadline: Int, src: String) -> Result[List[Int]]
  case File.read_bytes(handle, CHUNK, try time_left(deadline))
    ok(bytes) -> return ok(bytes)
    error(message) ->
      close_file(handle, close_budget(deadline))
      return error("archive: cannot read #{src}: #{message}")
  end
end

def start_decoder(handle: FileHandle, deadline: Int) -> Result[ZlibDecoder]
  case Zlib.inflate_init(31, INPUT_BYTES, SCAN_BYTES)
    ok(decoder) -> return ok(decoder)
    error(message) ->
      close_file(handle, close_budget(deadline))
      return error("archive: cannot start gzip decoding: #{message}")
  end
end

def make_dest(dest: String, deadline: Int) -> Result[Void]
  case Dir.mkdir_private(dest, try time_left(deadline))
    ok(_) -> return ok()
    error(message) -> return error("archive: cannot create #{dest}: #{message}")
  end
end

def read_chunk(handle: FileHandle, n: Int, deadline: Int, src: String) -> Result[List[Int]]
  case File.read_bytes(handle, n, try time_left(deadline))
    ok(bytes) -> return ok(bytes)
    error(message) -> return error("archive: cannot read #{src}: #{message}")
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

# Reads until `carry` holds `need` bytes, the file ends, or a gzip member ends. Counts every byte against the caps.
def fill(cur: Cursor, input: Input, need: Int, deadline: Int, src: String) -> Result[Cursor]
  while cur.carry.size < need
    case input
      Input.Raw(handle) ->
        if cur.file_eof
          break
        end
        room = SCAN_BYTES - cur.out_total
        if room <= 0
          probe = try read_chunk(handle, 1, deadline, src)
          if probe.size == 0
            cur = cur.with(file_eof: true)
            break
          end
          return error("archive: raw input exceeds 1073741824 bytes")
        end
        chunk = try read_chunk(handle, smaller(room, CHUNK), deadline, src)
        if chunk.size == 0
          cur = cur.with(file_eof: true)
        else
          cur = cur.with(
            carry: List.concat(cur.carry, chunk),
            out_total: cur.out_total + chunk.size,
            raw_read: cur.raw_read + chunk.size,
          )
        end
      Input.Gzip(g) ->
        if cur.stream_done
          break
        end
        if cur.pending.size == 0 and !cur.file_eof
          room = INPUT_BYTES - cur.raw_read
          if room <= 0
            probe = try read_chunk(g.handle, 1, deadline, src)
            if probe.size == 0
              cur = cur.with(file_eof: true)
            else
              return error("archive: compressed input exceeds 268435456 bytes")
            end
          else
            chunk = try read_chunk(g.handle, smaller(room, CHUNK), deadline, src)
            if chunk.size == 0
              cur = cur.with(file_eof: true)
            else
              cur = cur.with(
                pending: List.concat(cur.pending, chunk),
                raw_read: cur.raw_read + chunk.size,
              )
            end
          end
        else
          feed = List.take(cur.pending, CHUNK)
          rest = List.drop(cur.pending, feed.size)
          quantum = smaller(SCAN_BYTES - cur.out_total, CHUNK)
          if quantum <= 0
            quantum = 1
          end
          if Time.monotonic_ms() >= deadline
            return error("archive: operation timed out")
          end
          step = try inflate_step(g.dec, feed, quantum)
          cur = cur.with(
            pending: List.concat(List.drop(feed, step.consumed), rest),
            carry: List.concat(cur.carry, step.output),
            out_total: cur.out_total + step.output.size,
          )
          if cur.out_total > SCAN_BYTES
            return error("archive: decompressed input exceeds 1073741824 bytes")
          end
          if step.finished
            if cur.pending.size > 0
              return error("archive: trailing bytes after the gzip member")
            end
            cur = cur.with(stream_done: true)
          else
            if feed.size == 0 and cur.pending.size == 0 and cur.file_eof and step.needs_input
              return error("archive: gzip stream is truncated")
            end
          end
        end
    end
  end
  return ok(cur)
end

# Takes exactly `n` bytes, failing on truncation. Callers keep `n` small except through `skip_exact`.
def take_exact(cur: Cursor, input: Input, n: Int, deadline: Int, src: String, what: String) -> Result[TakeOut]
  if n < 0
    return error("archive: negative read of #{n} bytes for #{what}")
  end
  if n == 0
    return ok(TakeOut(cursor: cur, bytes: []))
  end
  got: List[Int] = []
  rest = n
  while rest > 0
    cur = try fill(cur, input, smaller(rest, CHUNK), deadline, src)
    if cur.carry.size == 0
      return error("archive: truncated TAR data, needed #{n} bytes for #{what}")
    end
    k = smaller(rest, cur.carry.size)
    got = List.concat(got, List.take(cur.carry, k))
    cur = cur.with(carry: List.drop(cur.carry, k))
    rest -= k
  end
  return ok(TakeOut(cursor: cur, bytes: got))
end

# Skips exactly `n` bytes without holding them, failing on truncation.
def skip_exact(cur: Cursor, input: Input, n: Int, deadline: Int, src: String, what: String) -> Result[Cursor]
  rest = n
  while rest > 0
    out = try take_exact(cur, input, smaller(rest, CHUNK), deadline, src, what)
    cur = out.cursor
    rest -= out.bytes.size
  end
  return ok(cur)
end

# Reads one 512-byte header, or reports the clean end of the stream.
def next_block(cur: Cursor, input: Input, deadline: Int, src: String) -> Result[BlockOut]
  cur = try fill(cur, input, HEADER_BYTES, deadline, src)
  if cur.carry.size == 0
    return ok(BlockOut(cursor: cur, done: true, block: []))
  end
  if cur.carry.size < HEADER_BYTES
    return error("archive: truncated TAR data, needed 512 bytes for a header")
  end
  block = List.take(cur.carry, HEADER_BYTES)
  cur = cur.with(carry: List.drop(cur.carry, HEADER_BYTES))
  return ok(BlockOut(cursor: cur, done: false, block: block))
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

def inflate_step(dec: ZlibDecoder, feed: List[Int], quantum: Int) -> Result[ZlibProgress]
  case Zlib.inflate_next(dec, feed, quantum)
    ok(progress) -> return ok(progress)
    error(message) -> return error("archive: gzip input is invalid: #{message}")
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

# Writes one selected regular file, streaming its content in bounded chunks within both output caps.
def create_out(out: String, deadline: Int) -> Result[FileHandle]
  case File.open(out, "create_private", try time_left(deadline))
    ok(opened) -> return ok(opened)
    error(message) -> return error("archive: cannot create #{out}: #{message}")
  end
end

def write_selected(
  cur: Cursor,
  input: Input,
  ctx: Ctx,
  index: Int,
  size: Int,
  deadline: Int,
  src: String,
) -> Result[WriteOut]
  item = ctx.wanted[index]
  out = try join_under(ctx.dest, item.segments)
  fold = String.downcase(out)
  if Map.has_key?(ctx.seen_fold, fold)
    return error("archive: selected files collide on a case-insensitive system: #{out}")
  end
  ctx = try make_parents(ctx, item.segments, deadline)
  if size > ctx.max_output or ctx.extracted + size > ctx.max_output
    return error("archive: output exceeds #{ctx.max_output} bytes")
  end
  handle = try create_out(out, deadline)
  rest = size
  while rest > 0
    piece = try take_exact(cur, input, smaller(rest, CHUNK), deadline, src, "file data of #{item.path}")
    cur = piece.cursor
    case File.write_bytes(handle, piece.bytes, try time_left(deadline))
      ok(_) -> rest -= piece.bytes.size
      error(message) ->
        close_file(handle, close_budget(deadline))
        return error("archive: cannot write #{out}: #{message}")
    end
  end
  case File.close(handle, close_budget(deadline))
    ok(_) -> ctx = ctx.with(
      matched: List.set(ctx.matched, index, true),
      counts: List.set(ctx.counts, index, size),
      extracted: ctx.extracted + size,
      seen_fold: Map.put(ctx.seen_fold, fold, true),
      seen_exact: Map.put(ctx.seen_exact, out, true),
    )
    error(message) -> return error("archive: cannot finish #{out}: #{message}")
  end
  return ok(WriteOut(cursor: cur, ctx: ctx))
end

# Consumes one entry: metadata updates the overrides, a selected regular file is written, the rest is skipped.
def consume_entry(
  cur: Cursor,
  input: Input,
  block: List[Int],
  entry: Int,
  ctx: Ctx,
  deadline: Int,
  src: String,
) -> Result[EntryOut]
  header = try read_header(block, entry)
  if header.typeflag == 120 or header.typeflag == 103
    is_global = header.typeflag == 103
    if header.size > META_BYTES - ctx.meta_used
      return error("archive: metadata exceeds 65536 bytes at entry #{entry}")
    end
    data = try take_exact(cur, input, header.size, deadline, src, "PAX data")
    next = try parse_pax(data.bytes, entry, is_global, ctx.with(meta_used: ctx.meta_used + header.size))
    padded = try skip_pad(data.cursor, input, header.size, deadline, src)
    return ok(EntryOut(cursor: padded, ctx: next))
  end
  if header.typeflag == 76 or header.typeflag == 75
    if header.size > META_BYTES - ctx.meta_used
      return error("archive: metadata exceeds 65536 bytes at entry #{entry}")
    end
    data = try take_exact(cur, input, header.size, deadline, src, "GNU long name data")
    padded = try skip_pad(data.cursor, input, header.size, deadline, src)
    ctx = ctx.with(meta_used: ctx.meta_used + header.size)
    if header.typeflag == 76
      trimmed = trim_nul(data.bytes)
      if trimmed.size > NAME_BYTES
        return error("archive: entry name is too long at entry #{entry}")
      end
      ctx = ctx.with(has_gnu_name: true, gnu_name: trimmed)
    end
    return ok(EntryOut(cursor: padded, ctx: ctx))
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
  if index >= 0
    try check_relative(canon, "entry name", " at entry #{entry}")
    if ctx.matched[index]
      return error("archive: the same archive holds #{canon} twice")
    end
    if !regular
      return error("archive: member is not a regular file: #{canon}")
    end
    written = try write_selected(cur, input, ctx, index, size, deadline, src)
    padded = try skip_pad(written.cursor, input, size, deadline, src)
    return ok(EntryOut(cursor: padded, ctx: written.ctx))
  end
  cur = try skip_exact(cur, input, size, deadline, src, "entry data")
  cur = try skip_pad(cur, input, size, deadline, src)
  return ok(EntryOut(cursor: cur, ctx: ctx))
end

# Skips the zero padding after `size` data bytes up to the next 512-byte block.
def skip_pad(cur: Cursor, input: Input, size: Int, deadline: Int, src: String) -> Result[Cursor]
  pad = (HEADER_BYTES - size % HEADER_BYTES) % HEADER_BYTES
  return skip_exact(cur, input, pad, deadline, src, "entry padding")
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

# Drains the bytes after the two zero end blocks: only zeros may follow, up to the caps.
def check_padding(cur: Cursor, input: Input, deadline: Int, src: String) -> Result[Cursor]
  while true
    cur = try fill(cur, input, 1, deadline, src)
    if cur.carry.size == 0
      break
    end
    piece = List.take(cur.carry, smaller(cur.carry.size, CHUNK))
    counts = List.tally(piece)
    if Map.size(counts) != 1 or !Map.has_key?(counts, 0)
      return error("archive: non-zero padding after the archive end")
    end
    cur = cur.with(carry: List.drop(cur.carry, piece.size))
  end
  return ok(cur)
end

# Proves a gzip member ends the file: any byte after it is trailing garbage.
def check_trailing(cur: Cursor, input: Input, deadline: Int, src: String) -> Result[Cursor]
  case input
    Input.Raw(_) -> return ok(cur)
    Input.Gzip(g) ->
      while true
        room = INPUT_BYTES - cur.raw_read
        if room <= 0
          probe = try read_chunk(g.handle, 1, deadline, src)
          if probe.size == 0
            break
          end
          return error("archive: compressed input exceeds 268435456 bytes")
        end
        chunk = try read_chunk(g.handle, smaller(room, CHUNK), deadline, src)
        if chunk.size == 0
          break
        end
        return error("archive: trailing bytes after the gzip member")
      end
      return ok(cur.with(file_eof: true))
  end
end

# Scans the whole container through the end blocks, the padding and every selected payload.
def scan_all(
  cur: Cursor,
  input: Input,
  ctx: Ctx,
  members: List[String],
  deadline: Int,
  src: String,
) -> Result[List[Int]]
  zeros = 0
  while true
    got = try next_block(cur, input, deadline, src)
    cur = got.cursor
    if got.done
      return error("archive: truncated archive, missing the two zero end blocks")
    end
    if is_zero_block(got.block)
      zeros += 1
      if zeros == 2
        break
      end
    else
      zeros = 0
      if ctx.entries >= MAX_ENTRIES
        return error("archive: too many entries, past 8192")
      end
      done = try consume_entry(cur, input, got.block, ctx.entries + 1, ctx, deadline, src)
      cur = done.cursor
      ctx = done.ctx.with(entries: done.ctx.entries + 1)
    end
  end
  cur = try check_padding(cur, input, deadline, src)
  cur = try check_trailing(cur, input, deadline, src)
  try check_missing(ctx, members)
  return ok(ctx.counts)
end
