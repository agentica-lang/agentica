# Task.cancel on a sleeping task, a task parked on a receive, a busy loop with no park, a task that ended, and twice;
# an await of a cancelled Task[Result[Int]] gives error("task: cancelled"). A cancelled task that nobody awaits is not
# a crash: the run ends with exit 0 and no summary.
def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def sleeper(ready: Channel[Int]) -> Result[Int]
  try ready.send(1, 5000)
  Task.sleep(600000)
  puts("never: sleeper")
  return ok(1)
end

def listener(inbox: Channel[Int]) -> Result[Int]
  n = try inbox.recv(600000)
  puts("never: listener")
  return ok(n)
end

def spinner(ready: Channel[Int]) -> Result[Int]
  try ready.send(3, 5000)
  i = 0
  while i >= 0
    i = i + 1
  end
  puts("never: spinner")
  return ok(i)
end

def quick(n: Int) -> Result[Int]
  return ok(n * 2)
end

def forgotten(n: Int) -> Void
  Task.sleep(n)
  puts("never: forgotten")
end

def main() -> Void
  ready: Channel[Int] = Channel.new(4)
  a = Task.spawn(&sleeper, ready)
  puts("sleeper ready #{ready.recv(5000).unwrap!}")
  Task.cancel(a)
  Task.cancel(a)
  report("sleeper", Task.await(a))
  report("sleeper again", Task.await(a))

  inbox: Channel[Int] = Channel.new(1)
  b = Task.spawn(&listener, inbox)
  Task.sleep(0)
  Task.cancel(b)
  report("listener", Task.await(b))
  case inbox.send(9, 0)
    ok(_) -> puts("the value stays in the channel: #{inbox.recv(0).unwrap!}")
    error(e) -> puts("send: #{e}")
  end

  c = Task.spawn(&spinner, ready)
  puts("spinner ready #{ready.recv(5000).unwrap!}")
  Task.cancel(c)
  case Task.await(c, 5000)
    Await.Done(r) -> report("spinner", r)
    Await.TimedOut -> puts("spinner: timed out")
  end

  d = Task.spawn(&quick, 21)
  report("quick", Task.await(d))
  Task.cancel(d)
  report("quick after cancel", Task.await(d))

  Task.cancel(Task.spawn(&forgotten, 600000))
  puts("main returns")
end
