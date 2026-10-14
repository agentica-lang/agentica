def linger(ms: Int) -> Void
  Task.sleep(ms)
end

def parent(handles: Channel[Task[Void]]) -> Result[Int]
  child = Task.spawn(&linger, 60000)
  handles.send(child, 5000)
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  handles: Channel[Task[Void]] = Channel.new(1)
  owner = Task.spawn(&parent, handles)
  child = handles.recv(5000).unwrap!
  case Task.await(owner)
    ok(n) -> puts(n)
    error(e) -> puts("parent: #{e}")
  end
  puts("waiting for the child")
  Task.await(child)
  puts("not reached")
end
