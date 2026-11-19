---
title: Heap (std)
weight: 4
description: El módulo std/heap, una cola de prioridad de cualquier tipo en el orden que tú le des.
source_hash: "ca7ae5a38bd2"
---

`std/heap` está escrito en Agentica: `import Heap from "std/heap"`.

Un heap es un valor inmutable `Heap.Heap[T]` que guarda valores de cualquier tipo. Le das el orden a `new` con una función `before`: es verdadera cuando su primer valor sale antes que el segundo, así que `a < b` da primero el más pequeño y `a > b` primero el más grande. Usa un orden estricto (`<` o `>`, no `<=`); el heap sigue funcionando con uno no estricto, pero los valores empatados salen en un orden que no está fijado. Cada función da un nuevo heap; asígnalo para conservarlo, o continúa con `Popped.remaining`. `pop` y `peek` en un heap vacío devuelven un Result de error con la clase `heap.empty`.

`push` y `pop` usan O(log n) pasos; `peek`, `size` y `empty?` usan O(1).

## Heap.new y Heap.from {#heapnew-and-heapfrom}

```signature
Heap.new(before: Fn[T, T, Bool]) -> Heap.Heap[T]
Heap.from(values: List[T], before: Fn[T, T, Bool]) -> Heap.Heap[T]
```

`new` da un heap vacío; `from` añade cada valor de una lista.

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

## Heap.push {#heappush}

```signature
Heap.push(heap: Heap.Heap[T], value: T) -> Heap.Heap[T]
```

Añade un valor.

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

## Heap.pop {#heappop}

```signature
Heap.pop(heap: Heap.Heap[T]) -> Result[Heap.Popped[T]]
```

Toma el primer valor. Da un `Popped` con `value` y el heap `remaining`, o un error cuando el heap está vacío.

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

## Heap.peek {#heappeek}

```signature
Heap.peek(heap: Heap.Heap[T]) -> Result[T]
```

Lee el primer valor sin quitarlo.

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

## Heap.size y Heap.empty? {#heapsize-and-heapempty}

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

## Heap.to_a {#heapto_a}

```signature
Heap.to_a(heap: Heap.Heap[T]) -> List[T]
```

Da cada valor en el orden en que `pop` los toma, en O(n log n).

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
