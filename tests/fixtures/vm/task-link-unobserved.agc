# One crash counts once however far a link carries it: the parent that failed with it counts no crash of its own, so
# the summary at the end of the run says 1, and a monitor through a TaskRef observes nothing.
def boom() -> Int = 10 / 0

def parent(refs: Channel[TaskRef]) -> Int
  _ = refs.send(Task.current, 1000)
  _child = Task.spawn_link(&boom)
  Task.sleep(600000)
  1
end

def main() -> Void
  refs: Channel[TaskRef] = Channel.new(1)
  inbox: Channel[String] = Channel.new(1)
  _task = Task.spawn(&parent, refs)
  Task.monitor(refs.recv(5000).unwrap!, inbox) do |down| "down #{down.reason} #{down.code}" end
  puts(inbox.recv(5000).unwrap!)
  puts(Task.unobserved_crash().ok?)
end
