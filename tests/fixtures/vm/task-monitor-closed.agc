# A notice for a closed channel is dropped without an error, and the other monitors of the task still get theirs.
def nothing() -> Int
  return 1
end

def main() -> Void
  closed: Channel[TaskDown] = Channel.new(1)
  closed.close
  inbox: Channel[String] = Channel.new(1)
  task = Task.spawn(&nothing)
  Task.monitor(task, closed) do |down| down end
  Task.monitor(task, inbox) do |down| "down #{down.reason}" end
  puts(inbox.recv(5000))
  puts(closed.recv(0))
  puts(Task.await(task))
end
