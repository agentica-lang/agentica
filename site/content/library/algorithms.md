---
title: Algorithms
weight: 7
description: Short runnable recipes for sorting, breadth-first search, memoization and recursion.
---

Small programs that use the library together. Values are immutable, so each recipe passes state along instead of changing it. For the functions used here, see [List](/library/data-structures/list/), [Map](/library/data-structures/map/) and [Result](/library/errors/result/).

## Sorting with sort_by

`List.sort_by` sorts by the key a block gives. To sort the largest first, use a negative key.

```agentica
struct Player
  name: String
  score: Int
end

def main() -> Void
  players = [
    Player(name: "Ana", score: 7),
    Player(name: "Bo", score: 12),
    Player(name: "Cy", score: 9)
  ]
  best_first = players.sort_by do |p| -p.score end   # negative key: largest first
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

## Breadth-first search

A breadth-first search visits the nodes nearest the start first, so the first time it reaches the goal it has used the fewest steps. A list is the queue (`head` is the next node to visit), and a map of distances doubles as the visited set. The graph maps each node to its neighbours.

```agentica
def shortest_path(graph: Map[String, List[String]], start: String, goal: String) -> Result[Int]
  queue = [start]
  head = 0
  distance: Map[String, Int] = {start: 0}
  while head < queue.size
    node = queue[head]
    head += 1
    steps = distance[node]
    if node == goal
      return ok(steps)
    end

    for next in graph.get(node, [])
      if not distance.key?(next)
        distance = distance.put(next, steps + 1)
        queue = queue.push(next)
      end
    end
  end

  return error("no path from #{start} to #{goal}")
end

def main() -> Void
  graph = {
    "home": ["shop", "park"],
    "shop": ["school"],
    "park": ["school", "lake"],
    "school": ["library"],
    "lake": [],
    "library": [],
    "island": []
  }
  puts(shortest_path(graph, "home", "library"))
  puts(shortest_path(graph, "home", "island"))
end
```

```output
ok(3)
error("no path from home to island")
```

## Memoization with a Map

Maps are immutable, so a memoized function returns its cache with the answer and passes the cache on. Without the cache, `fib(50)` would make billions of calls.

```agentica
struct Memo
  value: Int
  cache: Map[Int, Int]
end

def fib(n: Int, cache: Map[Int, Int]) -> Memo
  if n < 2
    return Memo(value: n, cache: cache)
  end

  if cache.key?(n)
    return Memo(value: cache[n], cache: cache)
  end

  left = fib(n - 1, cache)
  right = fib(n - 2, left.cache)
  total = left.value + right.value
  return Memo(value: total, cache: right.cache.put(n, total))
end

def main() -> Void
  cache: Map[Int, Int] = {}
  puts(fib(50, cache).value)
end
```

```output
12586269025
```

## Recursion

A recursive function calls itself on a smaller input and stops at a base case. A recursive enum, such as a tree, is walked the same way.

```agentica
# A tree is a leaf with a number, or a node with more trees inside.
enum Tree
  Leaf(Int)
  Node(List[Tree])
end

def factorial(n: Int) -> Int
  if n <= 1
    return 1                                   # base case
  end

  return n * factorial(n - 1)
end

# Every leaf of the tree, left to right: a node flattens each child.
def flatten(tree: Tree) -> List[Int]
  case tree
    Tree.Leaf(value) -> return [value]
    Tree.Node(children) ->
      return children.reduce([]) do |all, child| all.concat(flatten(child)) end
  end
end

# Moves needed for n disks: move n - 1 aside, move one, move n - 1 back on top.
def hanoi(n: Int, from: String, to: String, via: String) -> Int
  if n == 0
    return 0
  end

  return hanoi(n - 1, from, via, to) + 1 + hanoi(n - 1, via, to, from)
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
