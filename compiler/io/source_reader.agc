## Reads a source file from the disk: the whole file, as strict UTF-8, with no size limit.
##
## `File.read_text` stops at 1 MiB and `File.read_bytes` gives at most that many bytes per call, so the file is read
## in chunks of 256 KiB. Each chunk is decoded alone and the pieces are joined once. The decoding rules are those of
## syntax/source_file.agc, which holds no I/O.

import SourceFile from "../syntax/source_file"

# The deadline, in milliseconds, of each system call of a read.
IO_TIMEOUT_MS = 10_000

CHUNK_BYTES = 262_144

## Reads the file at `path`.
export def read(path: String) -> SourceFile.Read
  return read_as(path, false)
end

## Reads the file at `path` to show lines of it in a message: the text with U+FFFD in place of each byte that is not
## part of a valid sequence, as a lossy UTF-8 decoder does with that character.
## The result is never Invalid. The time is linear in the size of
## the file, bad bytes or not.
export def read_shown(path: String) -> SourceFile.Read
  return read_as(path, true)
end

def read_as(path: String, shown: Bool) -> SourceFile.Read
  opened = File.open(path, "read", IO_TIMEOUT_MS)
  if !opened.ok?
    return SourceFile.Read.Unreadable(opened.message)
  end

  handle = opened.unwrap!
  result = read_chunks(handle, shown)
  File.close(handle, IO_TIMEOUT_MS)
  return result
end

# The bytes of a character that a chunk cuts in two wait in `carry` for the next chunk.
def read_chunks(handle: FileHandle, shown: Bool) -> SourceFile.Read
  parts: List[String] = []
  carry: List[Int] = []
  finished = false
  while !finished
    got = File.read_bytes(handle, CHUNK_BYTES, IO_TIMEOUT_MS)
    if !got.ok?
      return SourceFile.Read.Unreadable(got.message)
    end

    chunk = got.unwrap!
    finished = chunk.size == 0
    data = carry.concat(chunk)
    cut = data.size
    if !finished
      cut = SourceFile.complete_prefix(data)
    end

    head = data.take(cut)
    carry = data.drop(cut)
    decoded = String.from_bytes(head)
    if decoded.ok?
      parts = parts.push(decoded.unwrap!)
    elsif shown
      parts = parts.push(SourceFile.replace_invalid(head))
    else
      return SourceFile.Read.Invalid(SourceFile.error_position(parts, head))
    end
  end

  return SourceFile.Read.Text(parts.join(""))
end
