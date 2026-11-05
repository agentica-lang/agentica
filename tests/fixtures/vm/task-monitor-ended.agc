# Monitors added after the task has ended get their notice at once, and two monitors of one task each get one.
def divide(n: Int) -> Result[Int]
  return ok(10 / n)
end

def show(inbox: Channel[TaskDown], label: String) -> Void
  down = inbox.recv(5000).unwrap!
  puts("#{label}: #{down.reason}")
end

def main() -> Void
  first: Channel[TaskDown] = Channel.new(1)
  second: Channel[TaskDown] = Channel.new(1)
  done = Task.spawn(&divide, 5)
  puts(Task.await(done))
  Task.monitor(done, first) do |down| down end
  show(first, "ended")
  crashed = Task.spawn(&divide, 0)
  Task.monitor(crashed, first) do |down| down end
  Task.monitor(crashed, second) do |down| down end
  show(first, "first monitor")
  show(second, "second monitor")
  Task.monitor(crashed, first) do |down| down end
  down = first.recv(5000).unwrap!
  puts("again: #{down.reason}, #{down.error.starts_with?("task crashed: RUNTIME-DIVISION-BY-ZERO")}")
  puts(Task.await(crashed).ok?)
end
