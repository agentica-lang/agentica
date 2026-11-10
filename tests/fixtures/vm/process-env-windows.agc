def main() -> Void
  args = ["-NoProfile", "-NonInteractive", "-Command", "$env:KEPT"]
  p = Process.spawn_captured("powershell.exe", args, Process.Options(timeout_ms: 60000, env: {"kept": "new", "ADDED": "ab"})).unwrap!
  out = Process.output(p, 60000).unwrap!
  IO.inspect(out.stdout.strip)
  Process.close(p)
  IO.inspect(Process.spawn("agc-no-such-program", [], Process.Options(timeout_ms: 60000, env: {"Path": "a", "PATH": "b"})).message)
  # Names that differ only in case are one variable on Windows, wherever they sit in the map, and also when the letter
  # is not ASCII. Two other letters are two variables.
  IO.inspect(Process.spawn("agc-no-such-program", [], Process.Options(timeout_ms: 60000, env: {"Path": "a", "PAT": "x", "pATH": "b"})).message)
  IO.inspect(Process.spawn("agc-no-such-program", [], Process.Options(timeout_ms: 60000, env: {"ä": "a", "B": "x", "Ä": "b"})).message)
  IO.inspect(Process.spawn("agc-no-such-program", [], Process.Options(timeout_ms: 60000, env: {"Ä": "a", "Ö": "b"})).message)
end
