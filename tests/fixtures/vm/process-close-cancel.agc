def closer(p: Process) -> Void
  Process.close(p)
  puts("closer: closed")
end

def parent(p: Process) -> Result[Int]
  Task.spawn_owning(&closer, p)
  Task.sleep(0)
  return ok(10 / List.size(System.args()))
end

def main() -> Void
  p = Process.spawn("sh", ["-c", "echo $$; exec cat"], 5000).unwrap!
  pid = Process.read_line(p, 5000).unwrap!
  t = Task.spawn_owning(&parent, p)
  puts(Task.await(t).ok?)
  script = "while kill -0 #{pid} 2>/dev/null; do sleep 0.02; done; echo gone"
  watcher = Process.spawn("sh", ["-c", script], 5000).unwrap!
  IO.inspect(Process.read_line(watcher, 5000))
  puts(Task.pending_count())
end
