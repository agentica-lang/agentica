def show(env: Map[String, String]) -> Void
  p = Process.spawn_captured("/bin/sh", ["-c", "echo \"$KEPT|$REPLACED|$ADDED|$EMPTY\""], "/", 60000, env).unwrap!
  IO.inspect(Process.read_line(p, 60000))
  Process.close(p)
end

def main() -> Void
  show({})
  show({"REPLACED": "new", "ADDED": "a b", "EMPTY": ""})
  plain = Process.spawn("/bin/sh", ["-c", "echo $ADDED"], 60000, {"ADDED": "plain"}).unwrap!
  IO.inspect(Process.read_line(plain, 60000))
  Process.close(plain)
  IO.inspect(System.env("ADDED").ok?)
  IO.inspect(Process.spawn("/bin/sh", [], 60000, {"": "x"}).message)
  IO.inspect(Process.spawn("/bin/sh", [], 60000, {"A=B": "x"}).message)
  IO.inspect(Process.spawn("/bin/sh", [], 60000, {"AGENTICA_CHANNEL": "3"}).message)
  IO.inspect(Process.spawn_channel("/bin/sh", [], ".", 60000, {"AGENTICA_VM_METRICS_FILE": "x"}).message)
  # Names that differ only in ASCII case are one variable on Windows, wherever they sit in the map; other letters
  # must match exactly there.
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Path": "a", "PAT": "x", "pATH": "b"}).message)
  IO.inspect(Process.spawn("agc-no-such-program", [], 60000, {"Ä": "a", "ä": "b"}).message)
end
