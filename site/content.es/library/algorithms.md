---
title: Algoritmos
weight: 7
description: Recetas cortas y ejecutables de ordenación, búsqueda en anchura, memoización y recursión.
source_hash: "ff4b63399798"
---

Programas pequeños que usan varias partes de la biblioteca. Los valores son inmutables, así que cada receta pasa el estado al siguiente paso en lugar de cambiarlo. Para las funciones que se usan aquí, consulta [List](/library/data-structures/list/), [Map](/library/data-structures/map/) y [Result](/library/errors/result/).

## Ordenar con sort_by {#sorting-with-sort_by}

`List.sort_by` ordena por la clave que da un bloque. Para ordenar primero el más grande, usa una clave negativa.

```agentica
struct Player
  name: String
  score: Int
end

def main() -> Void
  players = [Player(name: "Ana", score: 7), Player(name: "Bo", score: 12), Player(name: "Cy", score: 9)]
  best_first = players.sort_by do |p| -p.score end # negative key: largest first
  for p in best_first
    puts("#{p.name}: #{p.score}")
  end

  puts(["pear", "fig", "banana"].sort_by do |w| w.length end)
end
```

```output
Bo: 12
Cy: 9
Ana: 7
["fig", "pear", "banana"]
```

## Búsqueda en anchura {#breadth-first-search}

Una búsqueda en anchura visita primero los nodos más cercanos al inicio, así que la primera vez que llega a la meta ha usado el menor número de pasos. Una lista es la cola (`head` es el siguiente nodo por visitar), y un mapa de distancias sirve también como conjunto de visitados. El grafo asigna a cada nodo sus vecinos.

```agentica
def shortest_path(graph: Map[String, List[String]], start: String, goal: String) -> Result[Int]
  queue = [start]
  head = 0
  distance: Map[String, Int] = {start: 0}
  while head < queue.size
    node = queue[head]
    head += 1
    steps = distance[node]
    return ok(steps) if node == goal

    for next in graph.get(node, [])
      if not distance.key?(next)
        distance = distance.put(next, steps + 1)
        queue = queue.push(next)
      end
    end
  end

  error("no path from #{start} to #{goal}")
end

def main() -> Void
  graph = {
    "home": ["shop", "park"],
    "shop": ["school"],
    "park": ["school", "lake"],
    "school": ["library"],
    "lake": [],
    "library": [],
    "island": [],
  }

  puts(shortest_path(graph, "home", "library"))
  puts(shortest_path(graph, "home", "island"))
end
```

```output
ok(3)
error("no path from home to island")
```

## Memoización con un Map {#memoization-with-a-map}

Los mapas son inmutables, así que una función memoizada devuelve su caché junto con la respuesta y pasa la caché a la siguiente llamada. Sin la caché, `fib(50)` haría miles de millones de llamadas.

```agentica
struct Memo
  value: Int
  cache: Map[Int, Int]
end

def fib(n: Int, cache: Map[Int, Int]) -> Memo
  return Memo(value: n, cache: cache) if n < 2

  return Memo(value: cache[n], cache: cache) if cache.key?(n)

  left = fib(n - 1, cache)
  right = fib(n - 2, left.cache)
  total = left.value + right.value
  Memo(value: total, cache: right.cache.put(n, total))
end

def main() -> Void
  cache: Map[Int, Int] = {}
  puts(fib(50, cache).value)
end
```

```output
12586269025
```

## Recursión {#recursion}

Una función recursiva se llama a sí misma con una entrada más pequeña y se detiene en un caso base. Un enum recursivo, como un árbol, se recorre de la misma forma.

```agentica
# A tree is a leaf with a number, or a node with more trees inside.
enum Tree
  Leaf(Int)
  Node(List[Tree])
end

def factorial(n: Int) -> Int
  if n <= 1 # base case
    return 1
  end

  n * factorial(n - 1)
end

# Every leaf of the tree, left to right: a node flattens each child.
def flatten(tree: Tree) -> List[Int]
  case tree
    Tree.Leaf(value) -> [value]
    Tree.Node(children) -> children.reduce([]) do |all, child| all + flatten(child) end
  end
end

# Moves needed for n disks: move n - 1 aside, move one, move n - 1 back on top.
def hanoi(n: Int, from: String, to: String, via: String) -> Int
  return 0 if n == 0

  hanoi(n - 1, from, via, to) + 1 + hanoi(n - 1, via, to, from)
end

def main() -> Void
  puts(factorial(10))
  tree = Tree.Node([Tree.Leaf(1), Tree.Node([Tree.Leaf(2), Tree.Leaf(3)]), Tree.Leaf(4)])
  puts(flatten(tree))
  puts(hanoi(5, "a", "c", "b"))
end
```

```output
3628800
[1, 2, 3, 4]
31
```
