def double(inbox: Channel[Int]) -> Int
  n = inbox.recv(10000).unwrap!
  puts("worker got #{n}")
  return n * 2
end

def show(label: String, outcome: Await[Int]) -> Void
  case outcome
    Await.Done(n) -> puts("#{label}: done #{n}")
    Await.TimedOut -> puts("#{label}: timed out")
  end
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&double, inbox)
  show("first", Task.await(task, 20))
  puts("the caller goes on")
  IO.inspect(Task.await(task, 20))
  inbox.send(21, 1000)
  show("second", Task.await(task, 10000))
  show("settled", Task.await(task, 1))
  IO.inspect(Task.await(task, 1))
  puts("#{Task.await(task, 1)}")
  case Task.await(task, 1)
    Await.Done(n) -> puts("catch-all: #{n}")
    _ -> puts("catch-all: other")
  end
  puts(Task.await(task))
  puts(Task.pending_count())
end
