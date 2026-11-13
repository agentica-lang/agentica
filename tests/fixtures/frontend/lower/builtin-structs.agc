def main() -> Void
  info = File.stat("/tmp", 1000)
  case info
    ok(i) -> puts(i.kind)
    error(m) -> puts(m)
  end
  o = Process.Output(stdout: "", stderr: "", truncated: false)
  puts(o.truncated)
end
