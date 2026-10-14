def reader(p: Process) -> String
  return Process.channel_read_line(p, 60000).inspect
end

def sender(p: Process) -> String
  chunk = List.repeat("x", 1048000).join("")
  sent = Process.channel_send(p, chunk, 60000)
  while sent.ok?
    sent = Process.channel_send(p, chunk, 60000)
  end
  return sent.inspect
end

def holder(p: Process) -> Result[Int]
  Task.spawn(&reader, p)
  Task.spawn(&sender, p)
  Task.sleep(100)
  return ok(10 / List.size(System.args()))
end

def main() -> Void
  p = Process.spawn_channel("sh", ["-c", "exec sleep 60"], ".", 5000).unwrap!
  r = Task.spawn(&reader, p)
  s = Task.spawn(&sender, p)
  Task.sleep(100)
  Process.close(p)
  puts(Task.await(r))
  puts(Task.await(s))
  q = Process.spawn_channel("sh", ["-c", "exec sleep 60"], ".", 5000).unwrap!
  t = Task.spawn(&holder, q)
  puts(Task.await(t).ok?)
  Process.close(q)
  puts(Task.pending_count())
end
