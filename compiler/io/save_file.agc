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
