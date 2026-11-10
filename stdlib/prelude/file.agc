## The File methods of the compiler prelude (see list.agc). A is the type of the value the block gives.

# File.open with a block. The handle is closed on every way out of the block that gives a Result: its last
# expression, an early return and a failed try. A runtime error in the block ends the task, which closes what it owns.
# The close flushes the writes, so its error replaces an ok result; after an error result it is dropped.
def open(path: String, mode: String, timeout_ms: Int, f: Fn[FileHandle, Result[A]]) -> Result[A]
  handle = try File.open(path, mode, timeout_ms)
  result = f.call(handle)
  closed = File.close(handle, timeout_ms)
  case closed
    error(message) -> return error(message) if result.ok?

    ok(_) -> return result
  end
  return result
end
