def divide(inbox: Channel[Int]) -> Int
  return 100 / inbox.recv(10000).unwrap!
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&divide, inbox)
  IO.inspect(Task.await(task, 20))
  inbox.send(0, 1000)
  Task.sleep(50)
  puts("the caller is unaffected")
  puts(Task.unobserved_crash().ok?)
  Task.await(task, 1)
  puts("not reached")
end
