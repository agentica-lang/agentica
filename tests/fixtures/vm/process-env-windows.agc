def main() -> Void
  args = ["-NoProfile", "-NonInteractive", "-Command", "$env:KEPT"]
  p = Process.spawn_captured("powershell.exe", args, ".", 60000, {"kept": "new", "ADDED": "ab"}).unwrap!
  out = Process.output(p, 60000).unwrap!
  IO.inspect(out.stdout.strip)
  Process.close(p)
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Path": "a", "PATH": "b"}).message)
  # Names that differ only in ASCII case are one variable on Windows, wherever they sit in the map. A pair that differs
  # only in the case of a non-ASCII letter is not refused yet there, though Windows sees one variable (see #1041).
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Path": "a", "PAT": "x", "pATH": "b"}).message)
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Ä": "a", "ä": "b"}).message)
end
