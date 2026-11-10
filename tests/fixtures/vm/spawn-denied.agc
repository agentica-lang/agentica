def main() -> Void
  IO.inspect(Process.spawn("sh", ["-c", "echo hi"], Process.Options(timeout_ms: 5000)))
  IO.inspect(Process.spawn("", [], Process.Options(timeout_ms: 0)))
  puts(Result.ok?(Process.spawn("cat", [], Process.Options(timeout_ms: 5000))))
  p = Result.unwrap!(Process.spawn("cat", [], Process.Options(timeout_ms: 5000)))
  Process.close(p)
  puts("spawned")
end
