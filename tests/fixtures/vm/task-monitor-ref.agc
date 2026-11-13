# A monitor through a TaskRef (Task.current) does not observe the crash of the task: only the holder of its Task[R],
# which can await it, does. Nothing else observes this crash, so the run exits 1 after the notice.
def caller(refs: Channel[TaskRef]) -> Int
  _ = refs.send(Task.current, 1000)
  return 10 / 0
end

def main() -> Void
  refs: Channel[TaskRef] = Channel.new(1)
  inbox: Channel[String] = Channel.new(1)
  _task = Task.spawn(&caller, refs)
  Task.monitor(refs.recv(5000).unwrap!, inbox) do |down| "down #{down.reason}" end
  puts(inbox.recv(5000))
  puts(Task.unobserved_crash().ok?)
end
