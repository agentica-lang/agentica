# Any holder of a handle may cancel the task: a task that got the handle on a channel, the task itself (it stops after
# the call), and a descendant cancelling its ancestor (it is a descendant of what it cancels, so it stops too).
def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def worker(n: Int) -> Result[Int]
  Task.sleep(600000)
  puts("never: worker")
  return ok(n)
end

def stopper(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  target = try handles.recv(5000)
  Task.cancel(target)
  return ok(1)
end

def selfish(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  me = try handles.recv(5000)
  Task.cancel(me)
  puts("never: selfish")
  return ok(2)
end

def child(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  up = try handles.recv(5000)
  Task.cancel(up)
  puts("never: child")
  return ok(3)
end

def parent(handles: Channel[Task[Result[Int]]]) -> Result[Int]
  kid = Task.spawn(&child, handles)
  Task.sleep(600000)
  puts("never: parent")
  return ok(4)
end

def main() -> Void
  handles: Channel[Task[Result[Int]]] = Channel.new(1)
  w = Task.spawn(&worker, 7)
  s = Task.spawn(&stopper, handles)
  handles.send(w, 5000).unwrap!
  report("stopper", Task.await(s))
  report("worker", Task.await(w))

  me = Task.spawn(&selfish, handles)
  handles.send(me, 5000).unwrap!
  report("selfish", Task.await(me))

  p = Task.spawn(&parent, handles)
  handles.send(p, 5000).unwrap!
  report("parent", Task.await(p))
end
