## The files of a BDD run: new files that only the owner can read, written in pieces because one write takes at
## most 1 MiB.

import SaveFile from "../io/save_file"

## The deadline, in milliseconds, of each file system call of the driver.
IO_TIMEOUT = 10_000

## Writes bytes to a new file with mode 0600. It fails when the path exists (a link in the way included).
def write_bytes(path: String, bytes: Bytes) -> Result[Void]
  out = try File.open(path, "create_private", IO_TIMEOUT)
  written = SaveFile.write_all(out, bytes, IO_TIMEOUT)
  closed = File.close(out, IO_TIMEOUT)
  return written if !written.ok?

  closed
end

## Writes text to a new file with mode 0600, as write_bytes does.
def write_text(path: String, text: String) -> Result[Void]
  out = try File.open(path, "create_private", IO_TIMEOUT)
  at = 0
  while at < text.length
    size = PIECE_CHARACTERS
    if at + size > text.length
      size = text.length - at
    end

    written = File.write(out, text.slice(at, size), IO_TIMEOUT)
    if !written.ok?
      _ = File.close(out, IO_TIMEOUT)
      return written
    end

    at += size
  end

  File.close(out, IO_TIMEOUT)
end

private

# At most 1 MiB goes in one call. A character takes up to 4 bytes, so a piece of 250,000 characters always fits.
PIECE_CHARACTERS = 250_000
