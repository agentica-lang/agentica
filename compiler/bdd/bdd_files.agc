## The files of a BDD run: new files that only the owner can read, written in pieces because one write takes at
## most 1 MiB.

## The deadline, in milliseconds, of each file system call of the driver.
export IO_TIMEOUT = 10_000

# At most 1 MiB goes in one call. A character takes up to 4 bytes, so a piece of 250,000 characters always fits.
PIECE_BYTES = 1_048_576
PIECE_CHARACTERS = 250_000

## Writes bytes to a new file with mode 0600. It fails when the path exists (a link in the way included).
export def write_bytes(path: String, bytes: List[Int]) -> Result[Void]
  out = try File.open(path, "create_private", IO_TIMEOUT)
  rest = bytes
  while rest.size > 0
    written = File.write_bytes(out, rest.take(PIECE_BYTES), IO_TIMEOUT)
    if !written.ok?
      File.close(out, IO_TIMEOUT)
      return written
    end
    rest = rest.drop(PIECE_BYTES)
  end
  return File.close(out, IO_TIMEOUT)
end

## Writes text to a new file with mode 0600, as write_bytes does.
export def write_text(path: String, text: String) -> Result[Void]
  out = try File.open(path, "create_private", IO_TIMEOUT)
  at = 0
  while at < text.length
    size = PIECE_CHARACTERS
    if at + size > text.length
      size = text.length - at
    end
    written = File.write(out, text.slice(at, size), IO_TIMEOUT)
    if !written.ok?
      File.close(out, IO_TIMEOUT)
      return written
    end
    at += size
  end
  return File.close(out, IO_TIMEOUT)
end
