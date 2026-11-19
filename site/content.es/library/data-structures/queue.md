---
title: Cola (std)
weight: 4
description: El módulo std/queue, una cola de primero en entrar, primero en salir, de cadenas.
source_hash: "78adedf58c9c"
---

`std/queue` está escrito en Agentica: `import Queue from "std/queue"`.

Una cola es un valor inmutable `Queue.QueueState`. Cada función da una nueva cola; asígnala para conservarla, o continúa con `Popped.remaining`. Las entradas nunca cambian, y las cadenas vacías y los duplicados son válidos. `push` añade al final y `pop` quita el valor más antiguo; `pop` y `peek` en una cola vacía devuelven un Result de error.

La cola guarda solo valores `String`, y no hay operaciones bloqueantes entre tareas. `push`, `pop`, `peek`, `size` y `empty?` son O(n) con las operaciones de lista actuales; no se promete una FIFO de tiempo constante.

## Queue.new {#queuenew}

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

## Queue.push {#queuepush}

```signature
Queue.push(queue: Queue.QueueState, value: String) -> Queue.QueueState
```

Añade un valor al final.

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

## Queue.pop {#queuepop}

```signature
Queue.pop(queue: Queue.QueueState) -> Result[Queue.Popped]
```

Toma el valor más antiguo. Da un `Popped` con `value` y la cola `remaining`, o un error cuando la cola está vacía.

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

## Queue.peek {#queuepeek}

```signature
Queue.peek(queue: Queue.QueueState) -> Result[String]
```

Lee el valor más antiguo sin quitarlo.

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

## Queue.size y Queue.empty? {#queuesize-and-queueempty}

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
