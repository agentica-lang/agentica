# Task.current gives the handle of the running task, so a child can monitor its parent: the child learns when the
# parent ends, here after the parent has returned.
def watch_parent(parent: Task[Void], report: Channel[String]) -> Void
  downs: Channel[TaskDown] = Channel.new(1)
  Task.monitor(parent, downs) do |down| down end
  down = downs.recv(5000).unwrap!
  _ = report.send("parent ended: #{down.reason}, same id: #{down.task_id == parent.id}", 1000)
end

def parent(report: Channel[String]) -> Int
  me = Task.current
  _child = Task.spawn do watch_parent(me, report) end
  _ = report.send("parent returns", 1000)
  return 7
end

def main() -> Void
  report: Channel[String] = Channel.new(2)
  task = Task.spawn(&parent, report)
  puts(report.recv(5000).unwrap!)
  puts(report.recv(5000).unwrap!)
  puts(Task.await(task))
  puts(Task.current.id == Task.current.id)
end
