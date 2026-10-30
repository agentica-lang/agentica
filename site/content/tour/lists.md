---
title: Lists
weight: 8
description: List literals, indexing, adding elements and the common list methods.
---

## Make a list

A list holds values of one type, in order. Its type is written `List[T]`.

```agentica
def main() -> Void
  numbers = [3, 1, 2]
  names = ["Ana", "Bob"]
  puts(numbers)
  puts(names.size)
end
```

```output
[3, 1, 2]
2
```

Mixing types in a list is an error:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  mixed = [1, "two"]
end
```

An empty list needs a known type, for example from an annotation:

```agentica
def main() -> Void
  todo: List[String] = []
  puts(todo.size)
end
```

```output
0
```

## Read elements

Indexes start at 0. An index outside the list stops the program.

```agentica
def main() -> Void
  letters = ["a", "b", "c"]
  puts(letters[0])
  puts(letters[2])
end
```

```output
a
c
```

```agentica {expect="RUNTIME-INDEX-OUT-OF-RANGE"}
def main() -> Void
  letters = ["a", "b", "c"]
  puts(letters[3])
end
```

## Add and change

Lists never change in place. `push` gives a new list with one more element. `set` gives a new list with one element replaced.

```agentica
def main() -> Void
  xs = [1, 2]
  xs = xs.push(3)
  xs = xs.set(0, 10)
  puts(xs)
  puts(xs.concat([4, 5]))
end
```

```output
[10, 2, 3]
[10, 2, 3, 4, 5]
```

`xs[0] = 10` does not exist. Use `set`.

## Walk a list

Use `for`, or `each` with a block:

```agentica
def main() -> Void
  for n in [1, 2]
    puts(n)
  end

  ["x", "y"].each do |s|
    puts(s)
  end
end
```

```output
1
2
x
y
```

## Transform

`map`, `select` and `reduce` take a block and give a new value:

```agentica
def main() -> Void
  xs = [1, 2, 3, 4, 5]
  puts(xs.map do |x| x * x end)
  puts(xs.select do |x| x > 2 end)
  puts(xs.reduce(0) do |sum, x| sum + x end)
end
```

```output
[1, 4, 9, 16, 25]
[3, 4, 5]
15
```

## Sort, take, drop

```agentica
def main() -> Void
  xs = [5, 3, 8, 1]
  puts(xs.sort)
  puts(xs.reverse)
  puts(xs.take(2))
  puts(xs.drop(2))
end
```

```output
[1, 3, 5, 8]
[1, 8, 3, 5]
[5, 3]
[8, 1]
```

`sort_by` sorts by a key that a block gives:

```agentica
def main() -> Void
  words = ["pear", "fig", "banana"]
  puts(words.sort_by do |w| w.length end)
end
```

```output
["fig", "pear", "banana"]
```

## Ask questions

```agentica
def main() -> Void
  xs = [2, 4, 7]
  puts(xs.any? do |x| x > 5 end)
  puts(xs.all? do |x| x % 2 == 0 end)
end
```

```output
true
false
```

## Lists of lists

```agentica
def main() -> Void
  grid = [[1, 2], [3, 4]]
  puts(grid[1][0])
  puts(List.repeat(0, 3))
end
```

```output
3
[0, 0, 0]
```

Prefer `for` or `each` to visit every element. See the [List library page](/library/data-structures/list/) for every function.
