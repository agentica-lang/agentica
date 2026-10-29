## Bounded ZIP extraction for `std/archive`.
##
## Import it with `import Zip from "std/internal/archive_zip"`. Only a module of `std/` may import a module under
## `std/internal/`; the linker refuses any other importer, so this helper never becomes public API. `Archive` in
## `std/archive` is the only caller: it validates the `Options` ranges and delegates the whole call here.
##
## `extract_zip` copies an explicit allowlist of regular files out of a classic single-disk ZIP32 archive into a new
## private directory, and returns the byte counts in member order. There is no extract-all, no glob, no listing and
## no ZIP writer. Every failure is an `error` result, never a halt; a partial destination is kept on error and is
## only usable when the call returns `ok`.
##
## The reader is seek-free: three forward-only passes in 64 KiB reads, each opening the source again. The first pass
## reads the file once and keeps the last 65557 bytes to find the end-of-central-directory record; the second skips
## to the central directory and indexes its records; the third walks the local headers in physical order and streams
## the selected payloads. No pass reads more than 256 MiB, so the three passes together read at most 768 MiB of
## physical bytes plus bounded probes. The first two passes run before the destination is created, and the third
## validates every local record even after the selected files, so corruption past a selected file is still an error.
##
## Only stored (method 0) and raw deflate (method 8) entries are supported. Selected deflate payloads stream through
## `lazy.inflate(true, ...)` within the exact compressed window, and the CRC32 and the uncompressed size of every
## selected file are verified. Unselected payloads are skipped by their compressed size with structure and
## offset checks only: they are never inflated or CRC-checked. Data descriptors (bit 3) resolve against the sizes
## the central directory holds, never by scanning for the descriptor magic. Names need the UTF-8 flag to hold
## anything but ASCII; anything else is legacy CP437 and is refused, never misdecoded.

import Binary from "std/binary"

# Fixed ceilings, documented on `extract_zip`.
CHUNK = 65536
INPUT_BYTES = 268435456
TAIL_BYTES = 65557
MAX_ENTRIES = 8192
NAME_BYTES = 1024
MAX_MEMBERS = 256
CLOSE_MS = 5000
INT_MAX = 9223372036854775807

# The signatures of the central directory and a local header.
CD_MAGIC = [80, 75, 1, 2]
LOCAL_MAGIC = [80, 75, 3, 4]

# The general-purpose flag bits an entry may hold: 1 and 2 (deflate tuning), 3 (a data descriptor follows the data)
# and 11 (the name is UTF-8). Anything else, including the encryption bits 0 and 6, is refused.
FLAG_ALLOWED = 2062
FLAG_ENCRYPTED = 1
FLAG_DESCRIPTOR = 8
FLAG_UTF8 = 2048

# The highest "version needed to extract" an entry may name: 6.3. Stronger features (ZIP64 is 4.5) never reach here
# because their sentinels and extra fields are refused first.
VERSION_MAX = 63

# The Unix file-type bits read from the high word of the external attributes.
S_IFMT = 61440
S_IFREG = 32768
S_IFDIR = 16384

# The 0xFFFFFFFF sentinel that marks a ZIP64 field. Any field holding it is refused.
ZIP64_SENTINEL = 4294967295

# One validated allowlist member: the canonical archive path, its segments under the new base, the caller's spelling
# for errors, and its position in the caller's list.
struct Wanted
  path: String
  segments: List[String]
  text: String
  index: Int
end

# The parsed head of a central-directory record, before its name, extra and comment are read.
struct Head
  method: Int
  flags: Int
  crc: Int
  csize: Int
  usize: Int
  name_len: Int
  extra_len: Int
  comment_len: Int
  attrs: Int
  offset: Int
end

# One central-directory entry: everything the third pass needs, decoded and classified up front.
struct Entry
  index: Int
  offset: Int
  method: Int
  flags: Int
  crc: Int
  csize: Int
  usize: Int
  name: List[Int]
  canon: String
  regular: Bool
end

# The end-of-central-directory record: where it starts and what it promises.
struct Eocd
  start: Int
  count: Int
  cd_size: Int
  cd_offset: Int
end

# The first pass: the actual file size and the parsed end record.
struct Found
  size: Int
  eocd: Eocd
end

# The forward reader of one pass: the handle, the bytes read but not taken yet, and the physical accounting.
struct Stream
  handle: FileHandle
  buf: List[Int]
  raw: Int
  eof: Bool
end

# One piece of the compressed window of a deflated entry, as Lazy.produce gives it: the bytes read last, how many
# are still to read, and whether the window is over.
struct Piece
  bytes: Bytes
  left: Int
  done: Bool
end

# What the inflated bytes of one entry came to so far: their count and their CRC32.
struct Pump
  got: Int
  crc: Int
end

# The moved stream with the bytes a take produced.
struct TakeOut
  stream: Stream
  bytes: List[Int]
end

# A parsed local header: the moved stream and cursor, and whether a descriptor follows the data.
struct LocalOut
  stream: Stream
  cursor: Int
  descriptor: Bool
end

# A parsed data descriptor: the moved stream and cursor.
struct DescOut
  stream: Stream
  cursor: Int
end

# The moved stream, cursor and context after one local record.
struct StepOut
  stream: Stream
  cursor: Int
  ctx: Zctx
end

# The moved stream, cursor and context after one selected file.
struct WriteOut
  stream: Stream
  cursor: Int
  ctx: Zctx
end

# Everything the third pass carries besides the stream.
struct Zctx
  dest: String
  size: Int
  deadline: Int
  max_output: Int
  wanted: List[Wanted]
  by_name: Map[String, Int]
  matched: List[Bool]
  counts: List[Int]
  extracted: Int
  seen_fold: Map[String, Bool]
  seen_exact: Map[String, Bool]
end

## Copies the allowlisted `members` out of the ZIP archive at `src` into `dest_dir` and returns each file's bytes in
## member order.
##
## `timeout_ms` is the whole call in milliseconds and `max_output_bytes` caps the total of the extracted files; the
## caller (`Archive.extract_zip`) checks their ranges. `members` holds 1 to 256 safe relative paths, `dest_dir` is
## created private and must not exist, and only regular files are written. Fixed ceilings: the source is at most
## 256 MiB, the three passes together read at most 768 MiB of physical bytes, 8192 entries, 1024 name bytes, and
## names are strict UTF-8 when flag 11 is set and pure ASCII otherwise.
export def extract_zip(
  src: String,
  members: List[String],
  dest_dir: String,
  timeout_ms: Int,
  max_output_bytes: Int,
) -> Result[List[Int]]
  if timeout_ms <= 0 or timeout_ms > 86400000
    return error("archive: options.timeout_ms must be 1..86400000")
  end
  if max_output_bytes <= 0 or max_output_bytes > 1073741824
    return error("archive: options.max_output_bytes must be 1..1073741824")
  end
  now = Time.monotonic_ms()
  if now > INT_MAX - timeout_ms
    return error("archive: the clock is too far ahead for the timeout")
  end
  deadline = now + timeout_ms
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
  found = try pass1(src, deadline)
  entries = try pass2(src, found, deadline)
  try make_dest(dest, deadline)
  ordered = List.sort_by(entries) do |entry| entry.offset end
  by: Map[String, Int] = {}
  for item in wanted
    by = Map.put(by, item.path, item.index)
  end
  ctx = Zctx(
    dest: dest,
    size: found.size,
    deadline: deadline,
    max_output: max_output_bytes,
    wanted: wanted,
    by_name: by,
    matched: List.repeat(false, wanted.size),
    counts: List.repeat(0, wanted.size),
    extracted: 0,
    seen_fold: {},
    seen_exact: {},
  )
  outcome = try pass3(src, found, ordered, ctx)
  return ok(outcome)
end

def smaller(a: Int, b: Int) -> Int
  if a < b
    return a
  end
  return b
end

# Adds `b` to `a` within `cap`, for the counters that must never pass a ceiling. Operands that are already bounded
# (u32 fields plus small constants) use plain `+`, which cannot overflow.
def add_cap(a: Int, b: Int, cap: Int, message: String) -> Result[Int]
  if b < 0
    return error(message)
  end
  if a > cap - b
    return error(message)
  end
  return ok(a + b)
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

def open_src(src: String, deadline: Int) -> Result[FileHandle]
  case File.open(src, "read", try time_left(deadline))
    ok(opened) -> return ok(opened)
    error(message) -> return error("archive: cannot open #{src}: #{message}")
  end
end

def make_dest(dest: String, deadline: Int) -> Result[Void]
  case Dir.mkdir_private(dest, try time_left(deadline))
    ok(_) -> return ok()
    error(message) -> return error("archive: cannot create #{dest}: #{message}")
  end
end

# The ZIP reader holds headers and records as a List[Int], which std/binary reads, until #805 PR 7; the data of a
# deflated entry stays Bytes (read_raw).
def read_chunk(handle: FileHandle, n: Int, deadline: Int, src: String) -> Result[List[Int]]
  bytes = try read_raw(handle, n, deadline, src)
  return ok(bytes.to_a)
end

def read_raw(handle: FileHandle, n: Int, deadline: Int, src: String) -> Result[Bytes]
  case File.read_bytes(handle, n, try time_left(deadline))
    ok(bytes) -> return ok(bytes)
    error(message) -> return error("archive: cannot read #{src}: #{message}")
  end
end

# The bytes as strict UTF-8. The ZIP headers are a List[Int] until #805 PR 7; its items are bytes.
def utf8_of(data: List[Int]) -> Result[String]
  return String.from_bytes(try Bytes.from_list(data))
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

# Reads until `buf` holds `need` bytes or the file ends. Every physical byte counts against `cap`.
def stream_fill(st: Stream, need: Int, cap: Int, deadline: Int, src: String) -> Result[Stream]
  while st.buf.size < need
    if st.eof
      break
    end
    if Time.monotonic_ms() >= deadline
      return error("archive: operation timed out")
    end
    room = cap - st.raw
    if room <= 0
      probe = try read_chunk(st.handle, 1, deadline, src)
      if probe.size == 0
        st = st.with(eof: true)
        break
      end
      return error("archive: source exceeds #{INPUT_BYTES} bytes")
    end
    want = smaller(smaller(room, CHUNK), need - st.buf.size)
    chunk = try read_chunk(st.handle, want, deadline, src)
    if chunk.size == 0
      st = st.with(eof: true)
    else
      st = st.with(
        buf: List.concat(st.buf, chunk),
        raw: try add_cap(st.raw, chunk.size, cap, "archive: source exceeds #{INPUT_BYTES} bytes"),
      )
    end
  end
  return ok(st)
end

# Takes exactly `n` bytes, failing on truncation. Callers keep `n` small except through `stream_skip`.
def stream_take(
  st: Stream,
  n: Int,
  cap: Int,
  deadline: Int,
  src: String,
  what: String,
) -> Result[TakeOut]
  if n < 0
    return error("archive: negative read of #{n} bytes for #{what}")
  end
  if n == 0
    return ok(TakeOut(stream: st, bytes: []))
  end
  got: List[Int] = []
  rest = n
  while rest > 0
    st = try stream_fill(st, smaller(rest, CHUNK), cap, deadline, src)
    if st.buf.size == 0
      return error("archive: truncated ZIP data, needed #{n} bytes for #{what}")
    end
    k = smaller(rest, st.buf.size)
    got = List.concat(got, List.take(st.buf, k))
    st = st.with(buf: List.drop(st.buf, k))
    rest -= k
  end
  return ok(TakeOut(stream: st, bytes: got))
end

# Skips exactly `n` bytes without holding them, failing on truncation.
def stream_skip(st: Stream, n: Int, cap: Int, deadline: Int, src: String, what: String) -> Result[Stream]
  rest = n
  while rest > 0
    out = try stream_take(st, smaller(rest, CHUNK), cap, deadline, src, what)
    st = out.stream
    rest -= out.bytes.size
  end
  return ok(st)
end

def bytes_equal(a: List[Int], b: List[Int]) -> Bool
  if a.size != b.size
    return false
  end
  if a.size == 0
    return true
  end
  for i in 0..(a.size - 1)
    if a[i] != b[i]
      return false
    end
  end
  return true
end

def read_u16(buf: List[Int], at: Int, what: String) -> Result[Int]
  case Binary.read_u16_le(buf, at)
    ok(value) -> return ok(value)
    error(_) -> return error("archive: truncated ZIP data, #{what}")
  end
end

def read_u32(buf: List[Int], at: Int, what: String) -> Result[Int]
  case Binary.read_u32_le(buf, at)
    ok(value) -> return ok(value)
    error(_) -> return error("archive: truncated ZIP data, #{what}")
  end
end

def le_bytes(value: Int, what: String) -> Result[List[Int]]
  case Binary.write_u32_le(value)
    ok(bytes) -> return ok(bytes)
    error(_) -> return error("archive: bad size for #{what}")
  end
end

# Checks one relative path after its leading `./` is gone: no absolute, drive, UNC, backslash, colon or NUL content
# and no empty, `.` or `..` segments. `name` and `suffix` shape the error.
def check_relative(path: String, name: String, suffix: String) -> Result[String]
  if String.starts_with?(path, "/")
    return error("archive: #{name} is absolute#{suffix}")
  end
  for b in path.bytes
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
  if text.bytesize > NAME_BYTES
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
    wanted = List.append(
      wanted, Wanted(path: canon, segments: String.split(canon, "/"), text: text, index: wanted.size),
    )
  end
  return ok(wanted)
end

# The first pass: reads the whole source once, keeps the last TAIL_BYTES, and parses the end record.
def pass1(src: String, deadline: Int) -> Result[Found]
  handle = try open_src(src, deadline)
  outcome = scan_tail(handle, src, deadline)
  close_file(handle, close_budget(deadline))
  return outcome
end

def scan_tail(handle: FileHandle, src: String, deadline: Int) -> Result[Found]
  total = 0
  tail: List[Int] = []
  while true
    if Time.monotonic_ms() >= deadline
      return error("archive: operation timed out")
    end
    chunk = try read_chunk(handle, CHUNK, deadline, src)
    if chunk.size == 0
      break
    end
    total = try add_cap(total, chunk.size, INPUT_BYTES, "archive: source exceeds #{INPUT_BYTES} bytes")
    tail = List.concat(tail, chunk)
    if tail.size > TAIL_BYTES
      tail = List.drop(tail, tail.size - TAIL_BYTES)
    end
  end
  if total == 0
    return error("archive: #{src} is empty, not a ZIP archive")
  end
  if total < 22
    return error("archive: #{src} is not a ZIP archive")
  end
  eocd = try find_eocd(tail, total, src)
  return ok(Found(size: total, eocd: eocd))
end

# Parses one end-record candidate at tail offset `p`. With `from_anchor` the candidate must end exactly at the end
# of the file, and any field error reports; otherwise only fully field-valid candidates count, marking a structurally
# present end record that trailing junk pushed past the end. The earliest anchored candidate wins: a comment may
# itself hold the magic, and the true record is the outer one.
def parse_eocd_at(tail: List[Int], p: Int, size: Int, src: String, from_anchor: Bool) -> Result[Eocd]
  disk = try read_u16(tail, p + 4, "the end record is truncated")
  cd_disk = try read_u16(tail, p + 6, "the end record is truncated")
  this_count = try read_u16(tail, p + 8, "the end record is truncated")
  total_count = try read_u16(tail, p + 10, "the end record is truncated")
  cd_size = try read_u32(tail, p + 12, "the end record is truncated")
  cd_offset = try read_u32(tail, p + 16, "the end record is truncated")
  comment_len = try read_u16(tail, p + 20, "the end record is truncated")
  if disk != 0 or cd_disk != 0 or this_count != total_count
    return error("archive: multi-disk archives are not supported: #{src}")
  end
  if total_count > MAX_ENTRIES
    return error("archive: too many entries, past #{MAX_ENTRIES}")
  end
  if cd_size == ZIP64_SENTINEL or cd_offset == ZIP64_SENTINEL
    return error("archive: ZIP64 is not supported: #{src}")
  end
  start = size - tail.size + p
  if from_anchor and start + 22 + comment_len != size
    return error("archive: the end record does not end the file")
  end
  if cd_offset + cd_size != start
    return error("archive: the central directory does not abut the end record")
  end
  return ok(Eocd(start: start, count: total_count, cd_size: cd_size, cd_offset: cd_offset))
end

def find_eocd(tail: List[Int], size: Int, src: String) -> Result[Eocd]
  p = 0
  unanchored = false
  while p <= tail.size - 4
    if tail[p] == 80 and tail[p + 1] == 75 and tail[p + 2] == 5 and tail[p + 3] == 6
      if p + 22 > tail.size
        break
      end
      case read_u16(tail, p + 20, "the end record is truncated")
        ok(comment_len) ->
          if starts_at_end(tail, p, size, comment_len)
            return parse_eocd_at(tail, p, size, src, true)
          end
          case parse_eocd_at(tail, p, size, src, false)
            ok(_) ->
              unanchored = true
              p += 1
            error(_) -> p += 1
          end
        error(_) -> p += 1
      end
    else
      p += 1
    end
  end
  if unanchored
    return error("archive: the end record does not end the file")
  end
  return error("archive: the end of the central directory was not found: #{src}")
end

# True when the candidate at tail offset `p` with this comment length ends exactly at the end of the file: only
# then is it the end record, whose field errors report instead of scanning on.
def starts_at_end(tail: List[Int], p: Int, size: Int, comment_len: Int) -> Bool
  return size - tail.size + p + 22 + comment_len == size
end

# The second pass: skips to the central directory and indexes every record, validating all of it before the
# destination is created.
def pass2(src: String, found: Found, deadline: Int) -> Result[List[Entry]]
  handle = try open_src(src, deadline)
  outcome = scan_cd(handle, src, found, deadline)
  close_file(handle, close_budget(deadline))
  return outcome
end

def scan_cd(handle: FileHandle, src: String, found: Found, deadline: Int) -> Result[List[Entry]]
  st = Stream(handle: handle, buf: [], raw: 0, eof: false)
  eocd = found.eocd
  st = try stream_skip(st, eocd.cd_offset, INPUT_BYTES, deadline, src, "the central directory offset")
  entries: List[Entry] = []
  seen: Map[Int, Bool] = {}
  for i in 0..(eocd.count - 1)
    head = try stream_take(st, 46, INPUT_BYTES, deadline, src, "a central directory entry")
    st = head.stream
    parsed = try parse_cd_head(head.bytes, i + 1)
    name = try stream_take(st, parsed.name_len, INPUT_BYTES, deadline, src, "an entry name")
    st = name.stream
    extra = try stream_take(st, parsed.extra_len, INPUT_BYTES, deadline, src, "an entry extra field")
    st = extra.stream
    st = try stream_skip(st, parsed.comment_len, INPUT_BYTES, deadline, src, "an entry comment")
    try scan_zip64_extra(extra.bytes, i + 1)
    entry = try finish_entry(parsed, name.bytes, i + 1)
    if Map.has_key?(seen, entry.offset)
      return error("archive: duplicate local offset #{entry.offset} at entry #{entry.index}")
    end
    seen = Map.put(seen, entry.offset, true)
    entries = List.append(entries, entry)
  end
  if st.raw - eocd.cd_offset != eocd.cd_size
    return error("archive: the central directory holds #{st.raw - eocd.cd_offset} of #{eocd.cd_size} bytes")
  end
  return ok(entries)
end

def parse_cd_head(head: List[Int], index: Int) -> Result[Head]
  if !bytes_equal(List.take(head, 4), CD_MAGIC)
    return error("archive: bad central directory entry at entry #{index}")
  end
  needed = try read_u16(head, 6, "a central directory entry")
  if needed > VERSION_MAX
    return error("archive: unsupported version #{needed} at entry #{index}")
  end
  flags = try read_u16(head, 8, "a central directory entry")
  if Int.bit_and(flags, FLAG_ALLOWED) != flags
    if Int.bit_and(flags, FLAG_ENCRYPTED) == FLAG_ENCRYPTED
      return error("archive: encrypted entries are not supported at entry #{index}")
    end
    return error("archive: unsupported flags #{flags} at entry #{index}")
  end
  method = try read_u16(head, 10, "a central directory entry")
  if method != 0 and method != 8
    return error("archive: unsupported method #{method} at entry #{index}")
  end
  crc = try read_u32(head, 16, "a central directory entry")
  csize = try read_u32(head, 20, "a central directory entry")
  usize = try read_u32(head, 24, "a central directory entry")
  if csize == ZIP64_SENTINEL or usize == ZIP64_SENTINEL
    return error("archive: ZIP64 is not supported at entry #{index}")
  end
  name_len = try read_u16(head, 28, "a central directory entry")
  extra_len = try read_u16(head, 30, "a central directory entry")
  comment_len = try read_u16(head, 32, "a central directory entry")
  disk = try read_u16(head, 34, "a central directory entry")
  if disk != 0
    return error("archive: multi-disk archives are not supported at entry #{index}")
  end
  attrs = try read_u32(head, 38, "a central directory entry")
  offset = try read_u32(head, 42, "a central directory entry")
  if offset == ZIP64_SENTINEL
    return error("archive: ZIP64 is not supported at entry #{index}")
  end
  return ok(Head(
    method: method,
    flags: flags,
    crc: crc,
    csize: csize,
    usize: usize,
    name_len: name_len,
    extra_len: extra_len,
    comment_len: comment_len,
    attrs: attrs,
    offset: offset,
  ))
end

# Refuses the ZIP64 extra field wherever it appears: its tag means 32-bit fields cannot hold the sizes.
def scan_zip64_extra(extra: List[Int], index: Int) -> Result[Void]
  pos = 0
  while pos < extra.size
    if extra.size - pos < 4
      return error("archive: bad extra field at entry #{index}")
    end
    tag = extra[pos] + extra[pos + 1] * 256
    size = extra[pos + 2] + extra[pos + 3] * 256
    if tag == 1
      return error("archive: ZIP64 is not supported at entry #{index}")
    end
    pos += 4 + size
    if pos > extra.size
      return error("archive: bad extra field at entry #{index}")
    end
  end
  return ok()
end

# Decodes a central-directory name for matching: one leading `./` and any trailing `/` characters are removed, and
# anything undecodable, over-long or empty becomes `""`, which never matches a selector. Unmatched entries skip on
# this alone; only a matched entry faces the strict `check_relative` of the third pass.
def decode_canon(raw: List[Int], flags: Int, index: Int) -> Result[String]
  for b in raw
    if b == 0
      return ok("")
    end
  end
  path = ""
  if Int.bit_and(flags, FLAG_UTF8) == FLAG_UTF8
    case utf8_of(raw)
      ok(text) -> path = text
      error(_) -> return error("archive: entry name is not valid UTF-8 at entry #{index}")
    end
  else
    for b in raw
      if b >= 128
        return error("archive: non-ASCII names need the UTF-8 flag at entry #{index}")
      end
    end
    case utf8_of(raw)
      ok(text) -> path = text
      error(_) -> return ok("")
    end
  end
  if String.starts_with?(path, "./")
    path = String.slice(path, 2, String.length(path) - 2)
  end
  while String.length(path) > 0 and String.ends_with?(path, "/")
    path = String.slice(path, 0, String.length(path) - 1)
  end
  return ok(path)
end

# True for a regular file: no trailing slash, a regular Unix mode or no type information with no DOS directory bit.
def classify_regular(name: List[Int], attrs: Int) -> Bool
  if name.size > 0 and name[name.size - 1] == 47
    return false
  end
  high = attrs / 65536
  ftype = Int.bit_and(high, S_IFMT)
  if ftype == S_IFREG
    return true
  end
  if ftype == S_IFDIR
    return false
  end
  if ftype != 0
    return false
  end
  if Int.bit_and(attrs, 16) != 0
    return false
  end
  return true
end

def finish_entry(parsed: Head, name: List[Int], index: Int) -> Result[Entry]
  if parsed.name_len > NAME_BYTES or name.size > NAME_BYTES
    return error("archive: entry name is too long at entry #{index}")
  end
  if parsed.method == 0 and parsed.csize != parsed.usize
    return error("archive: bad sizes at entry #{index}")
  end
  if parsed.method == 8 and parsed.csize == 0
    return error("archive: empty deflate data at entry #{index}")
  end
  canon = try decode_canon(name, parsed.flags, index)
  regular = classify_regular(name, parsed.attrs)
  return ok(Entry(
    index: index,
    offset: parsed.offset,
    method: parsed.method,
    flags: parsed.flags,
    crc: parsed.crc,
    csize: parsed.csize,
    usize: parsed.usize,
    name: name,
    canon: canon,
    regular: regular,
  ))
end

# The third pass: walks the local headers in physical order, streaming the selected payloads and validating every
# record, even after the selected files.
def pass3(src: String, found: Found, ordered: List[Entry], ctx: Zctx) -> Result[List[Int]]
  handle = try open_src(src, ctx.deadline)
  outcome = walk_locals(handle, src, found, ordered, ctx)
  close_file(handle, close_budget(ctx.deadline))
  return outcome
end

def walk_locals(handle: FileHandle, src: String, found: Found, ordered: List[Entry], ctx: Zctx) -> Result[List[Int]]
  st = Stream(handle: handle, buf: [], raw: 0, eof: false)
  cursor = 0
  first = true
  for i in 0..(ordered.size - 1)
    entry = ordered[i]
    if first
      if entry.offset != 0
        return error("archive: the archive does not start with a local header")
      end
      first = false
    else
      if entry.offset != cursor
        return error("archive: local records overlap or leave a gap at offset #{cursor}")
      end
    end
    next_offset = found.eocd.cd_offset
    if i + 1 < ordered.size
      next_offset = ordered[i + 1].offset
    end
    stepped = try consume_entry(st, cursor, entry, next_offset, ctx, src)
    st = stepped.stream
    cursor = stepped.cursor
    ctx = stepped.ctx
  end
  if cursor != found.eocd.cd_offset
    return error("archive: trailing data before the central directory")
  end
  try check_missing(ctx)
  return ok(ctx.counts)
end

def consume_entry(
  st: Stream,
  cursor: Int,
  entry: Entry,
  next_offset: Int,
  ctx: Zctx,
  src: String,
) -> Result[StepOut]
  deadline = ctx.deadline
  local = try read_local(st, cursor, entry, ctx.size, deadline, src)
  st = local.stream
  cursor = local.cursor
  case Map.get(ctx.by_name, entry.canon)
    ok(index) ->
      canon = try check_relative(entry.canon, "entry name", " at entry #{entry.index}")
      if ctx.matched[index]
        return error("archive: the same archive holds #{canon} twice")
      end
      if !entry.regular
        return error("archive: member is not a regular file: #{canon}")
      end
      if entry.usize > ctx.max_output or ctx.extracted + entry.usize > ctx.max_output
        return error("archive: output exceeds #{ctx.max_output} bytes")
      end
      written = try write_selected(st, cursor, entry, index, next_offset, ctx, src)
      return ok(StepOut(stream: written.stream, cursor: written.cursor, ctx: written.ctx))
    error(_) ->
      st = try stream_skip(st, entry.csize, INPUT_BYTES, deadline, src, "entry data of #{entry.canon}")
      cursor = try add_cap(cursor, entry.csize, ctx.size, "archive: entry data runs past the central directory")
      if local.descriptor
        desc = try read_descriptor(st, cursor, entry, next_offset, deadline, src)
        st = desc.stream
        cursor = desc.cursor
      end
      return ok(StepOut(stream: st, cursor: cursor, ctx: ctx))
  end
end

# Parses one local header at `cursor` and checks it against the central directory: magic, version, flags, method,
# sizes (zero when a descriptor follows), the raw name bytes and the extra field.
def read_local(
  st: Stream,
  cursor: Int,
  entry: Entry,
  size: Int,
  deadline: Int,
  src: String,
) -> Result[LocalOut]
  head = try stream_take(st, 30, INPUT_BYTES, deadline, src, "a local header")
  st = head.stream
  buf = head.bytes
  if !bytes_equal(List.take(buf, 4), LOCAL_MAGIC)
    return error("archive: bad local header at offset #{cursor}")
  end
  needed = try read_u16(buf, 4, "a local header")
  if needed > VERSION_MAX
    return error("archive: unsupported version #{needed} at offset #{cursor}")
  end
  flags = try read_u16(buf, 6, "a local header")
  if flags != entry.flags
    return error("archive: local and central flags differ at entry #{entry.index}")
  end
  method = try read_u16(buf, 8, "a local header")
  if method != entry.method
    return error("archive: local and central methods differ at entry #{entry.index}")
  end
  crc = try read_u32(buf, 14, "a local header")
  csize = try read_u32(buf, 18, "a local header")
  usize = try read_u32(buf, 22, "a local header")
  descriptor = Int.bit_and(flags, FLAG_DESCRIPTOR) == FLAG_DESCRIPTOR
  if descriptor
    if crc != 0 or csize != 0 or usize != 0
      return error("archive: bad sizes at entry #{entry.index}")
    end
  else
    if crc != entry.crc or csize != entry.csize or usize != entry.usize
      return error("archive: local and central sizes differ at entry #{entry.index}")
    end
  end
  name_len = try read_u16(buf, 26, "a local header")
  extra_len = try read_u16(buf, 28, "a local header")
  cursor = try add_cap(cursor, 30, size, "archive: a local header runs past the end")
  name = try stream_take(st, name_len, INPUT_BYTES, deadline, src, "a local name")
  st = name.stream
  if !bytes_equal(name.bytes, entry.name)
    return error("archive: local and central names differ at entry #{entry.index}")
  end
  cursor = try add_cap(cursor, name_len, size, "archive: a local name runs past the end")
  extra = try stream_take(st, extra_len, INPUT_BYTES, deadline, src, "a local extra field")
  st = extra.stream
  try scan_zip64_extra(extra.bytes, entry.index)
  cursor = try add_cap(cursor, extra_len, size, "archive: a local extra field runs past the end")
  return ok(LocalOut(stream: st, cursor: cursor, descriptor: descriptor))
end

# Reads a data descriptor: 12 bytes, or 16 when the magic leads. The expected sizes come from the central
# directory and the record must end exactly where the next record starts, so a CRC equal to the magic resolves
# through the sizes and the bounds, never by scanning.
def read_descriptor(
  st: Stream,
  cursor: Int,
  entry: Entry,
  next_offset: Int,
  deadline: Int,
  src: String,
) -> Result[DescOut]
  first = try stream_take(st, 12, INPUT_BYTES, deadline, src, "a data descriptor")
  st = first.stream
  twelve = first.bytes
  expected = try expected_triple(entry)
  sig = twelve[0] == 80 and twelve[1] == 75 and twelve[2] == 7 and twelve[3] == 8
  if sig and cursor + 16 == next_offset
    rest = try stream_take(st, 4, INPUT_BYTES, deadline, src, "a data descriptor")
    st = rest.stream
    full = List.concat(twelve, rest.bytes)
    if bytes_equal(List.drop(full, 4), expected)
      cursor = try add_cap(cursor, 16, next_offset, "archive: bad data descriptor for #{entry.canon}")
      return ok(DescOut(stream: st, cursor: cursor))
    end
  end
  if bytes_equal(twelve, expected) and cursor + 12 == next_offset
    cursor = try add_cap(cursor, 12, next_offset, "archive: bad data descriptor for #{entry.canon}")
    return ok(DescOut(stream: st, cursor: cursor))
  end
  return error("archive: bad data descriptor for #{entry.canon}")
end

def expected_triple(entry: Entry) -> Result[List[Int]]
  crc = try le_bytes(entry.crc, "a data descriptor")
  csize = try le_bytes(entry.csize, "a data descriptor")
  usize = try le_bytes(entry.usize, "a data descriptor")
  return ok(List.concat(List.concat(crc, csize), usize))
end

def write_selected(
  st: Stream,
  cursor: Int,
  entry: Entry,
  index: Int,
  next_offset: Int,
  ctx: Zctx,
  src: String,
) -> Result[WriteOut]
  deadline = ctx.deadline
  item = ctx.wanted[index]
  out = try join_under(ctx.dest, item.segments)
  fold = String.downcase(out)
  if Map.has_key?(ctx.seen_fold, fold)
    return error("archive: selected files collide on a case-insensitive system: #{out}")
  end
  ctx = try make_parents(ctx, item.segments, deadline)
  handle = try create_out(out, deadline)
  if entry.method == 0
    case pump_stored(st, entry, handle, deadline, src)
      ok(done) -> st = done
      error(message) ->
        close_file(handle, close_budget(deadline))
        return error(message)
    end
  else
    case pump_deflated(st, entry, handle, deadline, src)
      ok(done) -> st = done
      error(message) ->
        close_file(handle, close_budget(deadline))
        return error(message)
    end
  end
  cursor = try add_cap(cursor, entry.csize, ctx.size, "archive: entry data runs past the central directory")
  if Int.bit_and(entry.flags, FLAG_DESCRIPTOR) == FLAG_DESCRIPTOR
    case read_descriptor(st, cursor, entry, next_offset, deadline, src)
      ok(desc) ->
        st = desc.stream
        cursor = desc.cursor
      error(message) ->
        close_file(handle, close_budget(deadline))
        return error(message)
    end
  end
  case File.close(handle, close_budget(deadline))
    ok(_) -> ctx = ctx.with(
      matched: List.set(ctx.matched, index, true),
      counts: List.set(ctx.counts, index, entry.usize),
      extracted: ctx.extracted + entry.usize,
      seen_fold: Map.put(ctx.seen_fold, fold, true),
      seen_exact: Map.put(ctx.seen_exact, out, true),
    )
    error(message) -> return error("archive: cannot finish #{out}: #{message}")
  end
  return ok(WriteOut(stream: st, cursor: cursor, ctx: ctx))
end

# Streams one stored file, chaining the CRC32 over 64 KiB pieces.
def pump_stored(st: Stream, entry: Entry, handle: FileHandle, deadline: Int, src: String) -> Result[Stream]
  rest = entry.csize
  crc = 0
  while rest > 0
    if Time.monotonic_ms() >= deadline
      return error("archive: operation timed out")
    end
    piece = try stream_take(st, smaller(rest, CHUNK), INPUT_BYTES, deadline, src, "file data of #{entry.canon}")
    st = piece.stream
    # The stream holds a List[Int] until #805 PR 7; its items are bytes.
    data = try Bytes.from_list(piece.bytes)
    case write_piece(handle, data, try time_left(deadline))
      ok(_) -> rest -= data.size
      error(message) -> return error("archive: cannot write a selected file: #{message}")
    end
    crc = try chain_crc(data, crc, entry.canon)
  end
  if crc != entry.crc
    return error("archive: CRC32 mismatch for #{entry.canon}: expected #{entry.crc}, got #{crc}")
  end
  return ok(st)
end

def write_piece(handle: FileHandle, piece: Bytes, timeout_ms: Int) -> Result[Void]
  return File.write_bytes(handle, piece, timeout_ms)
end

def chain_crc(piece: Bytes, crc: Int, canon: String) -> Result[Int]
  case Zlib.crc32(piece, crc)
    ok(next) -> return ok(next)
    error(message) -> return error("archive: cannot checksum #{canon}: #{message}")
  end
end

# Streams one deflated file through a raw inflate within the exact compressed window: every byte taken from the
# archive counts, leftover or missing bytes are an error, and the size and CRC32 must match. The window starts with
# the bytes the stream already read past the local header (at most csize of them, taken first) and goes on from the
# stream's handle, csize bytes in all.
def pump_deflated(st: Stream, entry: Entry, handle: FileHandle, deadline: Int, src: String) -> Result[Stream]
  held = List.take(st.buf, entry.csize)
  start = Piece(bytes: try Bytes.from_list(held), left: entry.csize - held.size, done: false)
  raw = try add_cap(st.raw, start.left, INPUT_BYTES, "archive: source exceeds #{INPUT_BYTES} bytes")
  cap = entry.usize
  if cap == 0
    cap = 1
  end
  source = st.handle
  outcome = Lazy.produce(start) do |piece: Piece| try next_piece(source, piece, deadline, src, entry.canon) end
    .take_while do |piece: Piece| !piece.done end
    .map do |piece: Piece| piece.bytes end
    .inflate(true, cap)
    .reduce(Pump(got: 0, crc: 0)) do |pump: Pump, out: Bytes| try pump_out(handle, pump, out, deadline, entry) end
  case outcome
    ok(pump) ->
      if pump.got != entry.usize
        return error("archive: size mismatch for #{entry.canon}: expected #{entry.usize}, got #{pump.got}")
      end
      if pump.crc != entry.crc
        return error("archive: CRC32 mismatch for #{entry.canon}: expected #{entry.crc}, got #{pump.crc}")
      end
      return ok(st.with(buf: List.drop(st.buf, held.size), raw: raw))
    error(message) -> return error(inflate_error(message, entry.canon))
  end
end

# The next piece of a compressed window, at most CHUNK bytes; a window that runs past the end of the file is
# truncated.
def next_piece(handle: FileHandle, piece: Piece, deadline: Int, src: String, canon: String) -> Result[Piece]
  if piece.left == 0
    return ok(Piece(bytes: "".bytes, left: 0, done: true))
  end
  if Time.monotonic_ms() >= deadline
    return error("archive: operation timed out")
  end
  want = smaller(piece.left, CHUNK)
  bytes = try read_raw(handle, want, deadline, src)
  if bytes.size < want
    return error("archive: truncated ZIP data, needed #{want} bytes for compressed data of #{canon}")
  end
  return ok(Piece(bytes: bytes, left: piece.left - want, done: false))
end

# Writes one inflated piece of a selected file and chains its CRC32.
def pump_out(handle: FileHandle, pump: Pump, out: Bytes, deadline: Int, entry: Entry) -> Result[Pump]
  case write_piece(handle, out, try time_left(deadline))
    ok(_) -> return ok(Pump(got: pump.got + out.size, crc: try chain_crc(out, pump.crc, entry.canon)))
    error(message) -> return error("archive: cannot write a selected file: #{message}")
  end
end

# The error of the inflate pipeline as std/archive words it. The zlib texts matched here are the ones vm/zlib.c gives
# (agc_zstep_next): keep them in step.
def inflate_error(message: String, canon: String) -> String
  if String.starts_with?(message, "archive: ")
    return message
  end
  if message == "zlib: trailing bytes after stream end"
    return "archive: trailing bytes after the deflate stream of #{canon}"
  end
  if message == "zlib: truncated stream"
    return "archive: truncated deflate data for #{canon}"
  end
  return "archive: deflate data is invalid for #{canon}: #{message}"
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
def make_parents(ctx: Zctx, segments: List[String], deadline: Int) -> Result[Zctx]
  if segments.size <= 1
    return ok(ctx)
  end
  parts: List[String] = [ctx.dest]
  for k in 0..(segments.size - 2)
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

def create_out(out: String, deadline: Int) -> Result[FileHandle]
  case File.open(out, "create_private", try time_left(deadline))
    ok(opened) -> return ok(opened)
    error(message) -> return error("archive: cannot create #{out}: #{message}")
  end
end

# Names every selected member that the archive never held.
def check_missing(ctx: Zctx) -> Result[Void]
  for item in ctx.wanted
    if !ctx.matched[item.index]
      return error("archive: member not found: #{item.text}")
    end
  end
  return ok()
end
