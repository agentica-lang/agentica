---
title: Tasks
weight: 14
description: Run work at the same time with lightweight tasks.
---

## Start a task

`Task.spawn` starts a function in a lightweight task. It takes a function
value and one argument. `Task.await` waits for the task and gives its result.

```agentica
def square(n: Int) -> Int
  return n * n
end

def main() -> Void
  task = Task.spawn(&square, 7)
  puts(Task.await(task))
end
```

```output
49
```

The task's type is `Task[R]`, where `R` is the result type of the function.

## Many tasks

Start all the tasks first, then wait for them. They make progress at the same
time, which helps when they wait for files or the network.

```agentica
def slow_double(n: Int) -> Int
  Task.sleep(10)
  return n * 2
end

def main() -> Void
  tasks = [1, 2, 3].map do |n| Task.spawn(&slow_double, n) end
  results = tasks.map do |t| Task.await(t) end
  puts(results)
end
```

```output
[2, 4, 6]
```

## More than one argument

A task function takes one argument. Pass a struct to send several values:

```agentica
struct Job
  name: String
  times: Int
end

def run(job: Job) -> String
  return "#{job.name.upcase} x#{job.times}"
end

def main() -> Void
  t = Task.spawn(&run, Job(name: "go", times: 2))
  puts(Task.await(t))
end
```

```output
GO x2
```

## Sleep

`Task.sleep(ms)` pauses the current task. `Task.sleep(0)` lets other tasks run.

```agentica
def main() -> Void
  start = Time.monotonic_ms()
  Task.sleep(20)
  puts(Time.monotonic_ms() - start >= 20)
end
```

```output
true
```

## Wait with a timeout

`Task.await(task, timeout_ms)` waits for at most that many milliseconds. It gives an `Await`: `Await.Done(value)` when the task ended in time, and `Await.TimedOut` when it did not. The task is not stopped, and you can await it again later.

```agentica
def double(inbox: Channel[Int]) -> Int
  n = inbox.recv(10000).unwrap!
  return n * 2
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&double, inbox)
  case Task.await(task, 20)
    Await.Done(n) -> puts("done #{n}")
    Await.TimedOut -> puts("still working")
  end
  inbox.send(21, 1000)
  case Task.await(task, 10000)
    Await.Done(n) -> puts("done #{n}")
    Await.TimedOut -> puts("gave up")
  end
end
```

```output
still working
done 42
```

## Rules

- `await` can be called more than once; it gives the same value.
- A timeout must be above 0. A timed `await` that times out leaves the task running.
- If a task other than `main` fails with an error, only that task stops. Its error is printed, the tasks it started are cancelled, and the files and sockets it opened are closed. Awaiting it gives an `error` when the task returns a `Result`, and stops the waiting task otherwise. A failure nobody awaited makes the program exit with code 1 at the end. An error in `main` still stops the whole program.
- A file, socket, listener or process belongs to the task that opened it, and it is closed when that task ends, however it ends. `Task.spawn_owning` gives one to the task it starts. It also takes a `Channel`, which is then closed when that task ends.
- When `main` returns, tasks that are still running are cancelled. Await the
  tasks you need.
- Tasks do not run on several CPU cores. Output from different tasks may come in any order.
- To pass values from one task to another, use a [Channel](/library/concurrency/channel/).

See [Task](/library/concurrency/task/) and [Channel](/library/concurrency/channel/) for the reference.
