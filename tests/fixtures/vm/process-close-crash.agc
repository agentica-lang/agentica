def crash(p: Process) -> Result[Int]
  return ok(10 / List.size(System.args()))
end

def watch(pid: String) -> Process
  script = "while kill -0 #{pid} 2>/dev/null; do sleep 0.02; done; echo gone"
  return Process.spawn("sh", ["-c", script], 5000).unwrap!
end

def main() -> Void
  plain = Process.spawn("sh", ["-c", "echo $$; exec cat"], 5000).unwrap!
  plain_pid = Process.read_line(plain, 5000).unwrap!
  captured = Process.spawn_captured("sh", ["-c", "echo $$; exec cat"], ".", 5000).unwrap!
  captured_pid = Process.read_line(captured, 5000).unwrap!
  a = Task.spawn_owning(&crash, plain)
  b = Task.spawn_owning(&crash, captured)
  puts(Task.await(a).ok?)
  puts(Task.await(b).ok?)
  IO.inspect(Process.read_line(watch(plain_pid), 5000))
  IO.inspect(Process.read_line(watch(captured_pid), 5000))
end
