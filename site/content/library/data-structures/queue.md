---
title: Queue (std)
weight: 4
description: The std/queue module, a first-in, first-out queue of strings.
---

`std/queue` is part of the standard library. It is written in Agentica itself. Import it with an alias: `import Queue from "std/queue"`.

A queue is an immutable `Queue.QueueState` value. Every function gives a new queue; assign it to keep it, or continue with `Popped.remaining`. Inputs are never changed, and empty strings and duplicates are valid. `push` adds at the back and `pop` removes the oldest value; `pop` and `peek` on an empty queue return an error Result.

The queue holds only `String` values, and there are no blocking cross-task operations. `push`, `pop`, `peek`, `size` and `empty?` are O(n) with the current list operations; no constant-time FIFO is promised.

## Queue.new

```signature
Queue.new() -> Queue.QueueState
```

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.new()
  puts(Queue.size(q))
end
```

```output
0
```

## Queue.push

```signature
Queue.push(queue: Queue.QueueState, value: String) -> Queue.QueueState
```

Adds a value at the back.

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.push(Queue.new(), "a")
  q = Queue.push(q, "b")
  puts(Queue.size(q))
end
```

```output
2
```

## Queue.pop

```signature
Queue.pop(queue: Queue.QueueState) -> Result[Queue.Popped]
```

Takes the oldest value. It gives a `Popped` with `value` and the `remaining` queue, or an error when the queue is empty.

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.push(Queue.push(Queue.new(), "a"), "b")
  popped = Queue.pop(q).unwrap!
  puts(popped.value)
  puts(Queue.size(popped.remaining))
  puts(Queue.pop(Queue.new()).ok?)
end
```

```output
a
1
false
```

## Queue.peek

```signature
Queue.peek(queue: Queue.QueueState) -> Result[String]
```

Reads the oldest value without removing it.

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.push(Queue.new(), "first")
  puts(Queue.peek(q))
end
```

```output
ok("first")
```

## Queue.size and Queue.empty?

```signature
Queue.size(queue: Queue.QueueState) -> Int
Queue.empty?(queue: Queue.QueueState) -> Bool
```

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.new()
  puts(Queue.empty?(q))
  q = Queue.push(q, "x")
  puts(Queue.empty?(q))
  puts(Queue.size(q))
end
```

```output
true
false
1
```
