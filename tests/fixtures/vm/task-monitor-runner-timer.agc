# The task that runs a monitor's wrap keeps the run waiting for its timers: here main awaits, with no timer of its
# own, a task that the wrap started and that sleeps, and the run does not stop as stalled.
def nap() -> Int
  Task.sleep(200)
  return 5
end

def main() -> Void
  started: Channel[Task[Int]] = Channel.new(1)
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn do 1 end
  Task.monitor(task, inbox) do |down|
    _ = started.send(Task.spawn(&nap), 0)
    down.task_id
  end

  napper = started.recv(5000).unwrap!
  puts(Task.await(napper))
  puts(inbox.recv(5000).unwrap! == task.id)
end
