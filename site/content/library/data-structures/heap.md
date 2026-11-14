---
title: Heap (std)
weight: 4
description: The std/heap module, a priority queue of any type in the order you give.
---

`std/heap` is part of the standard library. It is written in Agentica itself. Import it with an alias: `import Heap from "std/heap"`.

A heap is an immutable `Heap.Heap[T]` value that holds values of any type. You give the order to `new` as a function `before`: it is true when its first value comes out before its second, so `a < b` gives the smallest first and `a > b` the largest first. Every function gives a new heap; assign it to keep it, or continue with `Popped.remaining`. `pop` and `peek` on an empty heap return an error Result.

`push` and `pop` take O(log n) steps; `peek`, `size` and `empty?` take O(1). Equal values come out in no set order.

## Heap.new and Heap.from

```signature
Heap.new(before: Fn[T, T, Bool]) -> Heap.Heap[T]
Heap.from(values: List[T], before: Fn[T, T, Bool]) -> Heap.Heap[T]
```

`new` gives an empty heap; `from` pushes every value of a list.

```agentica
import Heap from "std/heap"

def main() -> Void
  empty = Heap.new do |a: Int, b: Int| a < b end
  puts(Heap.size(empty))
  largest = Heap.from(["fig", "pear", "apple"]) do |a: String, b: String| a.compare(b) > 0 end
  puts(Heap.peek(largest))
end
```

```output
0
ok("pear")
```

## Heap.push

```signature
Heap.push(heap: Heap.Heap[T], value: T) -> Heap.Heap[T]
```

Adds a value.

```agentica
import Heap from "std/heap"

def main() -> Void
  h = Heap.new do |a: Int, b: Int| a < b end
  h = Heap.push(h, 3)
  h = Heap.push(h, 1)
  puts(Heap.peek(h))
end
```

```output
ok(1)
```

## Heap.pop

```signature
Heap.pop(heap: Heap.Heap[T]) -> Result[Heap.Popped[T]]
```

Takes the first value. It gives a `Popped` with `value` and the `remaining` heap, or an error when the heap is empty.

```agentica
import Heap from "std/heap"

struct Job
  name: String
  priority: Int
end

def main() -> Void
  jobs = [Job(name: "mail", priority: 2), Job(name: "backup", priority: 9), Job(name: "log", priority: 5)]
  h = Heap.from(jobs) do |a: Job, b: Job| a.priority > b.priority end
  popped = Heap.pop(h).unwrap!
  puts(popped.value.name)
  puts(Heap.size(popped.remaining))
end
```

```output
backup
2
```

## Heap.peek

```signature
Heap.peek(heap: Heap.Heap[T]) -> Result[T]
```

Reads the first value without removing it.

```agentica
import Heap from "std/heap"

def main() -> Void
  h = Heap.new do |a: Int, b: Int| a < b end
  puts(Heap.peek(h).ok?)
  puts(Heap.peek(Heap.push(h, 7)))
end
```

```output
false
ok(7)
```

## Heap.size and Heap.empty?

```signature
Heap.size(heap: Heap.Heap[T]) -> Int
Heap.empty?(heap: Heap.Heap[T]) -> Bool
```

```agentica
import Heap from "std/heap"

def main() -> Void
  h = Heap.new do |a: Int, b: Int| a < b end
  puts(Heap.empty?(h))
  h = Heap.push(h, 4)
  puts(Heap.empty?(h))
  puts(Heap.size(h))
end
```

```output
true
false
1
```

## Heap.to_a

```signature
Heap.to_a(heap: Heap.Heap[T]) -> List[T]
```

Gives every value in the order `pop` takes them, in O(n log n).

```agentica
import Heap from "std/heap"

def main() -> Void
  h = Heap.from([5, 1, 4, 2]) do |a: Int, b: Int| a < b end
  puts(Heap.to_a(h))
end
```

```output
[1, 2, 4, 5]
```
