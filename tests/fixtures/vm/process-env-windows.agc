def main() -> Void
  p = Process.spawn_captured("cmd.exe", ["/d", "/c", "set", "KEPT"], ".", 60000, {"kept": "new", "ADDED": "ab"}).unwrap!
  out = Process.output(p, 60000).unwrap!
  IO.inspect(out.stdout.strip.upcase)
  IO.inspect(out.stderr)
  Process.close(p)
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Path": "a", "PATH": "b"}).message)
end
