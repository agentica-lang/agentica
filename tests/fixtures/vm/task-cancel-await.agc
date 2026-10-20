# An await of a cancelled task whose result is not a Result halts the caller with RUNTIME-TASK-CANCELLED.
def plain(ready: Channel[Int]) -> Int
  ready.send(4, 5000).unwrap!
  Task.sleep(600000)
  return 4
end

def main() -> Void
  ready: Channel[Int] = Channel.new(1)
  t = Task.spawn(&plain, ready)
  puts("ready #{ready.recv(5000).unwrap!}")
  Task.cancel(t)
  puts(Task.await(t))
end
