## Writing the bytes of a file: the front end's `compile` output and the harness of the bytecode writer.

# One File.write_bytes call takes at most 1 MiB.
PIECE = 1_048_576

## Writes the bytes to the file at `path`, which is created or truncated, in pieces of 1 MiB. Every call waits at most
## `timeout_ms`.
export def bytes(path: String, data: Bytes, timeout_ms: Int) -> Result[Void]
  out = try File.open(path, "write", timeout_ms)
  rest = data
  while rest.size > 0
    written = File.write_bytes(out, rest.take(PIECE), timeout_ms)
    if !written.ok?
      File.close(out, timeout_ms)
      return written
    end

    rest = rest.drop(PIECE)
  end

  return File.close(out, timeout_ms)
end

## Puts `data` in the file at `path` so that no reader sees a half-written file there. An old file (`replacing`) is
## replaced in one step by `File.replace`, which keeps its permission bits and writes through a symbolic link. A new
## file is written beside the path first and renamed into place (`Path.rename` never replaces, so a file made there
## meanwhile is kept); a step that fails removes what was made.
export def replace(path: String, data: Bytes, replacing: Bool, timeout_ms: Int) -> Result[Void]
  if replacing
    return File.replace(path, data, timeout_ms)
  end

  fresh = "#{path}.new-#{System.pid()}"
  placed = bytes(fresh, data, timeout_ms)
  if placed.ok?
    placed = Path.rename(fresh, path, timeout_ms)
  end

  if !placed.ok?
    Path.remove(fresh, timeout_ms)
  end

  return placed
end
