def run_tool() -> Result[Void]
  p = try Process.spawn("sh", ["-c", "echo hello from sh"], 5000)
  try Process.close_stdin(p, 5000)
  puts(try Process.read_line(p, 5000))
  code = try Process.wait(p, 5000)
  Process.close(p)
  if code != 0
    return error("tool exited with code " + String.from_int(code))
  end
  return ok()
end

def main() -> Void
  result = run_tool()
  if not Result.ok?(result)
    IO.warn(Result.message(result))
    System.exit(1)
  end
end
