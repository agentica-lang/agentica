def finish(inbox: Channel[Int]) -> Void
  n = inbox.recv(10000).unwrap!
  puts("finished #{n}")
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&finish, inbox)
  IO.inspect(Task.await(task, 20))
  inbox.send(7, 1000)
  case Task.await(task, 10000)
    Await.Done(_) -> puts("done")
    Await.TimedOut -> puts("timed out")
  end
  IO.inspect(Task.await(task, 1))
  puts("#{Task.await(task, 1)}")
end
