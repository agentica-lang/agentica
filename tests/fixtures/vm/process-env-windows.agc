def main() -> Void
  args = ["-NoProfile", "-NonInteractive", "-Command", "$env:KEPT"]
  p = Process.spawn_captured("powershell.exe", args, ".", 60000, {"kept": "new", "ADDED": "ab"}).unwrap!
  out = Process.output(p, 60000).unwrap!
  IO.inspect(out.stdout.strip)
  Process.close(p)
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Path": "a", "PATH": "b"}).message)
end
