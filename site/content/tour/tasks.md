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

`Task.map(items, limit, timeout_ms, f)` runs a function for each item, at most `limit` at a time. It gives one `Result` per item, in order. An item that runs longer than `timeout_ms` gets `error("task: timed out")`, and the other items go on. Use it for work that waits, such as HTTP requests. See [Task.map](/library/concurrency/task/#taskmap) for the rules and an example.

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

`Task.await(task, timeout_ms)` waits at most that many milliseconds, and gives `Await.Done(value)` or `Await.TimedOut`. The task keeps running. See [Task.await with a timeout](/library/concurrency/task/#taskawait-with-a-timeout).

## Rules

- A task other than `main` that fails stops alone: its error is printed, its child tasks are cancelled, and its files and sockets close. Awaiting it gives `error` if it returns a `Result`, else it stops the waiter. An unawaited failure makes the program exit with code 1.
- A file, socket, listener or process belongs to the task that opened it and closes when that task ends. `Task.spawn_owning` hands one (or a `Channel`) to the new task.
- When `main` returns, running tasks are cancelled. Await what you need.
- Tasks run on several CPU cores (`--schedulers 1` runs one at a time). Output may come in any order. To pass values between tasks, use a [Channel](/library/concurrency/channel/).

See [Task](/library/concurrency/task/) and [Channel](/library/concurrency/channel/) for the reference.
