## Reads a source file for the front end: the whole file, as strict UTF-8, with no size limit.
##
## `File.read_text` stops at 1 MiB and `File.read_bytes` gives at most that many bytes per call, so the file is read
## in chunks. Each chunk is decoded alone and the pieces are joined once, which costs time linear in the size of
## the file (`concat` of two large lists would copy again and again). The bytes of a character that a chunk cuts in
## two wait in `carry` for the next chunk.

import Diag from "../diagnostics/diagnostic"
import Source from "../syntax/source"

## What reading a source file gives: its text; the place of the first invalid byte (the position the lexer would
## have, counting the characters before it); or the system's message when the file cannot be read.
export enum Read
  Text(String)
  Invalid(Source.Position)
  Unreadable(String)
end

## Reads the file at `path`.
export def read(path: String, timeout_ms: Int) -> Read
  return read_as(path, timeout_ms, false)
end

## Reads the file at `path` to show lines of it in a message: the text with U+FFFD in place of each byte that is not
## part of a valid sequence, as a lossy UTF-8 decoder does with that character.
## The result is never Invalid. The time is linear in the size of
## the file, bad bytes or not.
export def read_shown(path: String, timeout_ms: Int) -> Read
  return read_as(path, timeout_ms, true)
end

## The LEX-INVALID-UTF8 diagnostic for the invalid byte at `at`: a span of length 1 that starts there.
export def invalid_utf8(at: Source.Position) -> Diag.Diagnostic
  stop = Source.Position(offset: at.offset + 1, line: at.line, column: at.column + 1)
  help = Diag.Help.Hint("source files are UTF-8: save the file as UTF-8 text")
  return Diag.fail("LEX-INVALID-UTF8", "source file is not valid UTF-8", Source.Span(start: at, stop: stop), help)
end

def read_as(path: String, timeout_ms: Int, shown: Bool) -> Read
  opened = File.open(path, "read", timeout_ms)
  if !opened.ok?
    return Read.Unreadable(opened.message)
  end
  handle = opened.unwrap!
  result = read_chunks(handle, timeout_ms, shown)
  File.close(handle, timeout_ms)
  return result
end

def read_chunks(handle: FileHandle, timeout_ms: Int, shown: Bool) -> Read
  parts: List[String] = []
  carry: List[Int] = []
  finished = false
  while !finished
    got = File.read_bytes(handle, 262144, timeout_ms)
    if !got.ok?
      return Read.Unreadable(got.message)
    end
    chunk = got.unwrap!
    finished = chunk.size == 0
    data = carry.concat(chunk)
    cut = data.size
    if !finished
      cut = complete_prefix(data)
    end
    head = data.take(cut)
    carry = data.drop(cut)
    decoded = String.from_bytes(head)
    if decoded.ok?
      parts = parts.push(decoded.unwrap!)
    elsif shown
      parts = parts.push(replace_invalid(head))
    else
      return Read.Invalid(error_position(parts, head))
    end
  end
  return Read.Text(parts.join(""))
end

# The text of `data` with U+FFFD (the bytes 239, 191, 189) for each byte at which no valid sequence starts, and
# decoding going on at the next byte: the rule of a UTF-8 decoder with an error character. One pass over the bytes
# that builds the bytes of the result with pushes (near constant time each), then one decoding. Cutting `data` into
# pieces with take and drop would copy the rest of it at every bad byte.
def replace_invalid(data: List[Int]) -> String
  out: List[Int] = []
  at = 0
  while at < data.size
    width = sequence_width(data, at)
    if width == 0
      out = out.concat([239, 191, 189])
      at += 1
    else
      for k in 0...width
        out = out.push(data[at + k])
      end
      at += width
    end
  end
  return String.from_bytes(out).unwrap!
end

# How many leading bytes of `data` end on a character boundary. A lead byte in the last three bytes whose
# sequence is not complete yet stays out, so the next chunk can finish it. Anything else (an invalid lead byte,
# a stray continuation byte) is left in: String.from_bytes then rejects it.
def complete_prefix(data: List[Int]) -> Int
  size = data.size
  back = 1
  while back <= 3 and back <= size
    byte = data[size - back]
    if byte < 128
      return size
    end
    if byte >= 192
      if lead_width(byte) > back
        return size - back
      end
      return size
    end
    back += 1
  end
  return size
end

# The length of the sequence a lead byte starts, or 0 when it cannot start one.
def lead_width(byte: Int) -> Int
  if byte >= 194 and byte <= 223
    return 2
  end
  if byte >= 224 and byte <= 239
    return 3
  end
  if byte >= 240 and byte <= 244
    return 4
  end
  return 0
end

# `head` did not decode. The position is that of the first invalid sequence, found by hand (the error path only).
# The characters, lines and columns before it are counted in loops: the decoded chunks
# by their newlines, and the valid bytes of `head` by their lead bytes. The text before it is never built in one piece.
def error_position(parts: List[String], head: List[Int]) -> Source.Position
  bad = first_invalid(head)
  valid = head.size
  if bad >= 0
    valid = bad
  end
  offset = 0
  line = 1
  since_newline = 0
  for part in parts
    pieces = part.split("\n")
    offset += part.length
    line += pieces.size - 1
    last = pieces[pieces.size - 1].length
    if pieces.size > 1
      since_newline = last
    else
      since_newline += last
    end
  end
  at = 0
  while at < valid
    byte = head[at]
    # A continuation byte (128 to 191) belongs to the character its lead byte started.
    if byte < 128 or byte >= 192
      offset += 1
      since_newline += 1
      if byte == 10
        line += 1
        since_newline = 0
      end
    end
    at += 1
  end
  return Source.Position(offset: offset, line: line, column: since_newline + 1)
end

# The index of the first byte of the first invalid sequence, or -1. The rules of agc_utf8_valid in vm/value.c.
def first_invalid(data: List[Int]) -> Int
  at = 0
  while at < data.size
    width = sequence_width(data, at)
    if width == 0
      return at
    end
    at += width
  end
  return -1
end

# The length of the valid sequence that starts at `at`, or 0: no overlong form, no surrogate, nothing above
# U+10FFFF, and no sequence cut short by the end of the data.
def sequence_width(data: List[Int], at: Int) -> Int
  lead = data[at]
  if lead < 128
    return 1
  end
  width = lead_width(lead)
  if width == 0 or at + width > data.size
    return 0
  end
  code = lead - 192
  if width == 3
    code = lead - 224
  end
  if width == 4
    code = lead - 240
  end
  for k in 1...width
    next_byte = data[at + k]
    if next_byte < 128 or next_byte > 191
      return 0
    end
    code = code * 64 + next_byte - 128
  end
  if (width == 3 and code < 2048) or (width == 4 and code < 65536) or code > 1114111
    return 0
  end
  if code >= 55296 and code <= 57343
    return 0
  end
  return width
end
