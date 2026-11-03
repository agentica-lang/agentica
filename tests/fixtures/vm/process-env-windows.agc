def main() -> Void
  p = Process.spawn_captured("cmd.exe", ["/d", "/c", "echo", "%KEPT%-%ADDED%"], ".", 60000, {"kept": "new", "ADDED": "ab"}).unwrap!
  IO.inspect(Process.read_line(p, 60000))
  Process.close(p)
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Path": "a", "PATH": "b"}).message)
end
