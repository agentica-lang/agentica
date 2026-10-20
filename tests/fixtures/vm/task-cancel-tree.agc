# Task.cancel reaches every descendant: children, grandchildren, and a grandchild whose own parent already ended (it
# moved up to the root). A channel that a cancelled task owns is closed, so a task parked on a receive sees the close.
def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def leaf(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  Task.sleep(600000)
  puts("never: leaf")
  return ok(0)
end

def branch(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  try handles.send(Task.spawn(&leaf, handles), 5000)
  try handles.send(Task.spawn(&leaf, handles), 5000)
  Task.sleep(600000)
  puts("never: branch")
  return ok(1)
end

def short(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  try handles.send(Task.spawn(&leaf, handles), 5000)
  return ok(2)
end

def root(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  try handles.send(Task.spawn(&branch, handles), 5000)
  try Task.await(Task.spawn(&short, handles))
  Task.sleep(600000)
  puts("never: root")
  return ok(3)
end

def keeper(mine: Channel[Int]) -> Result[Int]
  Task.sleep(600000)
  return ok(4)
end

def listener(mine: Channel[Int]) -> Result[Int]
  return mine.recv(600000)
end

def main() -> Void
  handles: Channel[Task[Result[Int]]] = Channel.new(8)
  top = Task.spawn(&root, handles)
  tasks = (1..4).to_a.map do |i|
    handles.recv(5000).unwrap!
  end
  Task.cancel(top)
  report("root", Task.await(top))
  for t in tasks
    report("descendant", Task.await(t))
  end

  mine: Channel[Int] = Channel.new(1)
  owner = Task.spawn_owning(&keeper, mine)
  reader = Task.spawn(&listener, mine)
  Task.sleep(0)
  Task.cancel(owner)
  report("owner", Task.await(owner))
  report("reader", Task.await(reader))
  puts("closed? #{mine.closed?}")
  puts("pending #{Task.pending_count()}")
end
