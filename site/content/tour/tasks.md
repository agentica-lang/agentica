---
title: Tasks
weight: 15
description: Run work at the same time with lightweight tasks.
---

## Start a task

`Task.spawn` starts a function in a lightweight task, with one argument, or with none for a function that takes no parameter. `Task.await` waits for it and gives the result.

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

The type is `Task[R]`, where `R` is the function's result type.

## Many tasks

Start all the tasks, then wait. They progress at the same time, which helps with files and the network.

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

## Many items, a few at a time

`Task.map(items, limit, timeout_ms)` runs a block for each item, at most `limit` at a time. It gives one `Result` per item, in order.

- The block returns a `Result`, so `try` works in it.
- An item running longer than `timeout_ms` is cancelled and gets `error("task: timed out")`. The other items go on.

```agentica
def fetch(n: Int) -> Result[String]
  if n == 2
    Task.sleep(10000)
  end
  return ok("page #{n}")
end

def main() -> Void
  pages = Task.map([1, 2, 3], 3, 200, &fetch)
  puts(pages)
end
```

```output
[ok("page 1"), error("task: timed out"), ok("page 3")]
```

Use it for work that waits, such as HTTP requests. For CPU work, a `limit` above the number of cores does not help. See [Task.map](/library/concurrency/task/#taskmap) for the rules.

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

`Task.await(task, timeout_ms)` waits at most that many milliseconds. It gives `Await.Done(value)` if the task ended in time, else `Await.TimedOut`. The task keeps running; you can await it again. See [Task.await with a timeout](/library/concurrency/task/#taskawait-with-a-timeout) for an example.

## Rules

- A task other than `main` that fails stops alone: its error is printed, its child tasks are cancelled, and its files and sockets close. Awaiting it gives `error` if it returns a `Result`, else it stops the waiter. An unawaited failure makes the program exit with code 1.
- A file, socket, listener or process belongs to the task that opened it and closes when that task ends. `Task.spawn_owning` hands one (or a `Channel`) to the new task.
- When `main` returns, running tasks are cancelled. Await what you need.
- Tasks run on several CPU cores (`--schedulers 1` runs one at a time). Output may come in any order. To pass values between tasks, use a [Channel](/library/concurrency/channel/).

See [Task](/library/concurrency/task/) and [Channel](/library/concurrency/channel/) for the reference.
