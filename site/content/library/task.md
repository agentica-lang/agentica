---
title: Task
weight: 9
description: Start, await and pause lightweight tasks.
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
