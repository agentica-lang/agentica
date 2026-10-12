def main() -> Void
  IO.inspect(Process.spawn("sh", ["-c", "echo hi"], 5000))
  IO.inspect(Process.spawn("", [], 0))
  puts(Result.ok?(Process.spawn("cat", [], 5000)))
  p = Result.unwrap!(Process.spawn("cat", [], 5000))
  Process.close(p)
  puts("spawned")
end
