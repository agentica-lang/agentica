# A monitor's notice for each way a task ends: a return, a crash and a cancel. The crash counts as observed, so the run
# exits 0.
enum Msg
  Down(TaskDown)
end

def divide(n: Int) -> Int
  return 10 / n
end

def wait_forever(inbox: Channel[Int]) -> Int
  return inbox.recv(600000).unwrap!
end

def watch(task: Task[Int], inbox: Channel[Msg]) -> Void
  Task.monitor(task, inbox) do |down| Msg.Down(down) end
  case inbox.recv(5000).unwrap!
    Msg.Down(down) ->
      puts("#{down.reason} same id: #{down.task_id == task.id}")
      puts("  #{down.code.inspect} #{down.message.inspect} #{down.file.end_with?("task-monitor-ends.agc")}")
      puts("  #{down.line}:#{down.column}")
  end
end

def main() -> Void
  inbox: Channel[Msg] = Channel.new(4)
  watch(Task.spawn(&divide, 2), inbox)
  watch(Task.spawn(&divide, 0), inbox)
  idle: Channel[Int] = Channel.new(1)
  waiting = Task.spawn(&wait_forever, idle)
  Task.cancel(waiting)
  watch(waiting, inbox)
  puts(Task.unobserved_crash().ok?)
end
