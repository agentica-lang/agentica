---
title: Task
weight: 1
description: Start, await, pause and count lightweight tasks, and find their crashes.
---

Tasks run functions at the same time in one program. The tour page
[Tasks](/tour/tasks/) shows how to use them.

## Task.spawn

```text
Task.spawn(function: Fn[A, R], argument: A) -> Task[R]
```

Starts `function(argument)` in a new task and gives a handle to it. A file, socket, listener or process belongs to the task that opened it. When the argument itself is such a handle, it moves to the new task, so a crash of the new task closes it. A handle inside a struct or a list stays with its owner. When a task returns normally, the handles it still owns go back to its parent task. If that task has ended, they go to the nearest ancestor that still runs.

```agentica
def greet(name: String) -> String
  return "hi #{name}"
end

def main() -> Void
  task = Task.spawn(&greet, "Ana")
  puts(Task.await(task))
end
```

```output
hi Ana
```

## Task.await

```text
Task.await(task: Task[R]) -> R
```

Waits for the task and gives its result. Waiting again gives the same value.

A runtime error in a task other than `main` is a crash: it ends only that
task. The error is printed on stderr, the task's own tasks are cancelled, and
the files, sockets, listeners and processes it opened are closed. When the
task returns a `Result`, awaiting it gives
`error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE")`. Otherwise the
waiting task stops with `RUNTIME-TASK-CRASHED`. A crash that no await sees
makes the run exit with code 1 when `main` returns.

An await that would wait for the awaiting task itself, directly or through other tasks, stops with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await`. A task can get such a handle through a [Channel](/library/concurrency/channel/).

```agentica
def parse(text: String) -> Result[Int]
  return ok(100 / text.to_i!)
end

def main() -> Void
  task = Task.spawn(&parse, "0")
  case Task.await(task)
    ok(n) -> puts(n)
    error(e) -> puts(e.starts_with?("task crashed: RUNTIME-DIVISION-BY-ZERO"))
  end
  puts("still running")
end
```

```output
true
still running
```

```agentica
def add_one(n: Int) -> Int
  return n + 1
end

def main() -> Void
  task = Task.spawn(&add_one, 1)
  puts(Task.await(task))
  puts(Task.await(task))
end
```

```output
2
2
```

## Task.sleep

```text
Task.sleep(milliseconds: Int) -> Void
```

Pauses the current task. `0` lets other tasks run. A negative value stops the
program.

```agentica
def late(label: String) -> String
  Task.sleep(30)
  puts(label)
  return label
end

def main() -> Void
  task = Task.spawn(&late, "second")
  puts("first")
  done = Task.await(task)
end
```

```output
first
second
```

A block can run in a task too, when you pass it through a function parameter:

```agentica
def start(f: Fn[Int, Int]) -> Task[Int]
  return Task.spawn(f, 20)
end

def main() -> Void
  task = start() do |n| n + 1 end
  puts(Task.await(task))
end
```

```output
21
```

## Task.pending_count

```text
Task.pending_count() -> Int
```

Gives how many tasks of this run have not ended yet, not counting `main`. A
task that waits to run, sleeps or waits for another task counts; so does the
task that asks, unless it is `main`. A task that has returned or crashed no
longer counts, even when nothing awaited it. `std/bdd` uses it to fail a [BDD](/library/testing/bdd/) step that leaves tasks
running.

```agentica
def wait_for(task: Task[Int]) -> Int
  return Task.await(task)
end

def nap(ms: Int) -> Int
  Task.sleep(ms)
  return ms
end

def main() -> Void
  puts(Task.pending_count())
  first = Task.spawn(&nap, 20)
  second = Task.spawn(&wait_for, first)
  puts(Task.pending_count())
  puts(Task.await(second))
  puts(Task.pending_count())
end
```

```output
0
2
20
0
```

## Task.unobserved_crash

```text
Task.unobserved_crash() -> Result[String]
```

Gives `ok(text)` with the first crash of this run that no `Task.await` has
seen, or an error when there is none. Asking does not count as seeing it.
`std/bdd` uses it to fail a [BDD](/library/testing/bdd/) step whose task crashed.

```agentica
def boom(n: Int) -> Int
  return 10 / n
end

def main() -> Void
  task = Task.spawn(&boom, 0)
  puts(Task.unobserved_crash().ok?)
  Task.sleep(0)
  puts(Task.unobserved_crash().ok?)
  System.exit(0)
end
```

```output
false
true
```
