---
title: Task
weight: 9
description: Start, await, pause and count lightweight tasks.
---

Tasks run functions at the same time in one program. The tour page
[Tasks](/tour/tasks/) shows how to use them.

## Task.spawn

```text
Task.spawn(function: Fn[A, R], argument: A) -> Task[R]
```

Starts `function(argument)` in a new task and gives a handle to it.

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
If the task failed, the whole program has already stopped with its error.

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
task that asks, unless it is `main`. A task that has returned no longer
counts, even when nothing awaited it. This function runs only on the VM.
`std/bdd` uses it to fail a [BDD](/library/bdd/) step that leaves tasks
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
