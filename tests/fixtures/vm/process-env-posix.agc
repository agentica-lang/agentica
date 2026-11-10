def show(env: Map[String, String]) -> Void
  p = Process.spawn_captured("/bin/sh", ["-c", "echo \"$KEPT|$REPLACED|$ADDED|$EMPTY\""], Process.Options(chdir: "/", timeout_ms: 60000, env: env)).unwrap!
  IO.inspect(Process.read_line(p, 60000))
  Process.close(p)
end

def main() -> Void
  show({})
  show({"REPLACED": "new", "ADDED": "a b", "EMPTY": ""})
  plain = Process.spawn("/bin/sh", ["-c", "echo $ADDED"], Process.Options(timeout_ms: 60000, env: {"ADDED": "plain"})).unwrap!
  IO.inspect(Process.read_line(plain, 60000))
  Process.close(plain)
  IO.inspect(System.env("ADDED").ok?)
  IO.inspect(Process.spawn("/bin/sh", [], Process.Options(timeout_ms: 60000, env: {"": "x"})).message)
  IO.inspect(Process.spawn("/bin/sh", [], Process.Options(timeout_ms: 60000, env: {"A=B": "x"})).message)
  IO.inspect(Process.spawn("/bin/sh", [], Process.Options(timeout_ms: 60000, env: {"AGENTICA_CHANNEL": "3"})).message)
  IO.inspect(Process.spawn_channel("/bin/sh", [], Process.Options(timeout_ms: 60000, env: {"AGENTICA_VM_METRICS_FILE": "x"})).message)
  # Names are compared byte for byte here, so names that differ only in case are two variables (one on Windows).
  IO.inspect(Process.spawn("agc-no-such-program", [], Process.Options(timeout_ms: 60000, env: {"Path": "a", "PAT": "x", "pATH": "b"})).message)
  IO.inspect(Process.spawn("agc-no-such-program", [], Process.Options(timeout_ms: 60000, env: {"Ä": "a", "ä": "b"})).message)
end
