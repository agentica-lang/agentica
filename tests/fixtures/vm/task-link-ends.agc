# A return or a cancel ends a link and leaves the other task running: the parent goes on after its linked child was
# cancelled, and a linked child goes on after its parent returned.

def quick() -> Int = 7

def waiting(idle: Channel[Int]) -> Result[Int] = idle.recv(600000)

def parent(idle: Channel[Int]) -> Int
  done = Task.spawn_link(&quick)
  puts("returned #{Task.await(done)}")
  cancelled = Task.spawn_link(&waiting, idle)
  Task.cancel(cancelled)
  puts("cancelled #{Task.await(cancelled).ok?}")
  Task.sleep(0)
  puts("parent runs on")
  1
end

def leaves(go: Channel[Int]) -> Task[Result[Int]] = Task.spawn_link(&waiting, go)

def main() -> Void
  idle: Channel[Int] = Channel.new(1)
  puts(Task.await(Task.spawn(&parent, idle)))
  go: Channel[Int] = Channel.new(1)
  child = Task.await(Task.spawn(&leaves, go))
  _ = go.send(5, 1000)
  puts(Task.await(child))
  puts(Task.pending_count())
end
