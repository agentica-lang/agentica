## Writing the bytes of a file: the front end's `compile` output and the harness of the bytecode writer.

# One File.write_bytes call takes at most 1 MiB.
PIECE = 1_048_576

## Writes the bytes to the file at `path`, which is created or truncated, in pieces of 1 MiB. Every call waits at most
## `timeout_ms`.
export def bytes(path: String, data: List[Int], timeout_ms: Int) -> Result[Void]
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

## Puts `data` in the file at `path` so that no reader sees a half-written file there: it is written to a file beside
## it first, and that file is renamed into place (`Path.rename` never replaces, so an old file, `replacing`, is moved
## to a backup name first and removed at the end). A step that fails puts the old file back and removes what was made.
export def replace(path: String, data: List[Int], replacing: Bool, timeout_ms: Int) -> Result[Void]
  stamp = System.pid()
  fresh = "#{path}.new-#{stamp}"
  backup = "#{path}.old-#{stamp}"
  written = bytes(fresh, data, timeout_ms)
  if !written.ok?
    Path.remove(fresh, timeout_ms)
    return written
  end
  if replacing
    moved = Path.rename(path, backup, timeout_ms)
    if !moved.ok?
      Path.remove(fresh, timeout_ms)
      return moved
    end
  end
  placed = Path.rename(fresh, path, timeout_ms)
  if !placed.ok?
    if replacing
      Path.rename(backup, path, timeout_ms)
    end
    Path.remove(fresh, timeout_ms)
    return placed
  end
  if replacing
    # The new file stands; a backup that cannot be removed is only a spare file.
    Path.remove(backup, timeout_ms)
  end
  return ok()
end
