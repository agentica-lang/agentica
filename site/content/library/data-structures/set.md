---
title: Set
weight: 3
description: Functions for Set[T], a collection of distinct Int or String values. Each one is also a method on sets.
---

A set holds each value once, in the order first added. Elements are `Int` or `String`, like map keys. Sets are immutable. Each function is also a method: `Set.size(s)` is `s.size`.

- `for` walks a set in order. A set prints as `Set[1, 2]`.
- There is no `==`; use `a.subset?(b) and b.subset?(a)`.
- A set is not JSON-encodable, so `JSON.encode` refuses it.

```agentica
def main() -> Void
  seen = Set.new(["b", "a", "b"])
  for name in seen
    puts(name)
  end
  puts(seen)
end
```

```output
b
a
Set["b", "a"]
```

## new

```text
Set.new(items: List[T]) -> Set[T]
```

Builds a set from a list. A repeated item is dropped, and the first one keeps its place. `T` must be `Int` or `String`, otherwise `CHECK-SET-ELEMENT-TYPE`. An empty list needs an expected type, like `[]` and `{}`: `CHECK-EMPTY-SET-TYPE` without one.

```agentica
def main() -> Void
  puts(Set.new([3, 1, 2, 3, 1]))
  none: Set[String] = Set.new([])
  puts(none)
end
```

```output
Set[3, 1, 2]
Set[]
```

## add

```text
Set.add(set: Set[T], value: T) -> Set[T]
```

Adds an element at the end. A member leaves the set as it is.

```agentica
def main() -> Void
  s = Set.new([1, 2])
  puts(s.add(3))
  puts(s.add(1))
  puts(s)
end
```

```output
Set[1, 2, 3]
Set[1, 2]
Set[1, 2]
```

## delete

```text
Set.delete(set: Set[T], value: T) -> Set[T]
```

Removes an element. A missing element is fine. An element added again later goes to the end.

```agentica
def main() -> Void
  s = Set.new(["a", "b", "c"])
  puts(s.delete("a"))
  puts(s.delete("zzz"))
  puts(s.delete("a").add("a"))
end
```

```output
Set["b", "c"]
Set["a", "b", "c"]
Set["b", "c", "a"]
```

## include?

```text
Set.include?(set: Set[T], value: T) -> Bool
```

Tests membership. It takes effectively constant time, like `Map.has_key?`.

```agentica
def main() -> Void
  s = Set.new([1, 2])
  puts(s.include?(2))
  puts(s.include?(5))
end
```

```output
true
false
```

## size and empty?

```text
Set.size(set: Set[T]) -> Int
Set.empty?(set: Set[T]) -> Bool
```

```agentica
def main() -> Void
  s = Set.new([4, 4, 5])
  puts(s.size)
  puts(s.empty?)
  puts(s.delete(4).delete(5).empty?)
end
```

```output
2
false
true
```

## to_a

```text
Set.to_a(set: Set[T]) -> List[T]
```

The elements in first-insertion order.

```agentica
def main() -> Void
  puts(Set.new([9, 7, 9, 8]).to_a)
end
```

```output
[9, 7, 8]
```

## union, intersection and difference

```text
Set.union(a: Set[T], b: Set[T]) -> Set[T]
Set.intersection(a: Set[T], b: Set[T]) -> Set[T]
Set.difference(a: Set[T], b: Set[T]) -> Set[T]
```

`union` gives the elements of `a`, then the elements of `b` that `a` lacks. `intersection` and `difference` keep the order of `a`.

```agentica
def main() -> Void
  a = Set.new([1, 2, 3, 4])
  b = Set.new([4, 3, 9])
  puts(a.union(b))
  puts(a.intersection(b))
  puts(a.difference(b))
  puts(b.difference(a))
end
```

```output
Set[1, 2, 3, 4, 9]
Set[3, 4]
Set[1, 2]
Set[9]
```

## subset?

```text
Set.subset?(a: Set[T], b: Set[T]) -> Bool
```

True when every element of `a` is in `b`. The empty set is a subset of every set.

```agentica
def main() -> Void
  small = Set.new([2, 3])
  big = Set.new([1, 2, 3])
  puts(small.subset?(big))
  puts(big.subset?(small))
  puts(small.subset?(small))
end
```

```output
true
false
true
```
