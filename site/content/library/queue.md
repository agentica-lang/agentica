---
title: Queue (std)
weight: 14
description: The std/queue module, a first-in, first-out queue of strings.
---

`std/queue` is part of the standard library. It is written in Agentica
itself. Import it with an alias: `import "std/queue" as Queue`.

A queue is an immutable `Queue.QueueState` value. Every function gives a new
queue; assign it to keep it.

## Queue.new

```text
Queue.new() -> Queue.QueueState
```

```agentica
import "std/queue" as Queue

def main() -> Void
  q = Queue.new()
  puts(Queue.size(q))
end
```

```output
0
```

## Queue.push

```text
Queue.push(q: Queue.QueueState, value: String) -> Queue.QueueState
```

Adds a value at the back.

```agentica
import "std/queue" as Queue

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

```text
Queue.pop(q: Queue.QueueState) -> Result[Queue.Popped]
```

Takes the oldest value. It gives a `Popped` with `value` and the `remaining`
queue, or an error when the queue is empty.

```agentica
import "std/queue" as Queue

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

```text
Queue.peek(q: Queue.QueueState) -> Result[String]
```

Reads the oldest value without removing it.

```agentica
import "std/queue" as Queue

def main() -> Void
  q = Queue.push(Queue.new(), "first")
  puts(Queue.peek(q))
end
```

```output
ok("first")
```

## Queue.size and Queue.empty?

```text
Queue.size(q: Queue.QueueState) -> Int
Queue.empty?(q: Queue.QueueState) -> Bool
```

```agentica
import "std/queue" as Queue

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
