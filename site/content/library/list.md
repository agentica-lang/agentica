---
title: List
weight: 2
description: Functions for List[T]. Each one is also a method on lists.
---

Lists are immutable. Every function gives a new list and leaves its input as it
was. Every function here is also a method: `List.size(xs)` is `xs.size`.
`xs.length` is the same as `xs.size`, and `xs.push(x)` is `List.append(xs, x)`.

## size

```text
List.size(list: List[T]) -> Int
```

```agentica
def main() -> Void
  puts([1, 2, 3].size)
end
```

```output
3
```

## at

```text
List.at(list: List[T], index: Int) -> T
```

The same as `list[index]`. A bad index stops the program.

```agentica
def main() -> Void
  puts(["a", "b"].at(1))
end
```

```output
b
```

## append

```text
List.append(list: List[T], value: T) -> List[T]
```

Adds a value at the end. `push` is the method alias.

```agentica
def main() -> Void
  xs = [1, 2]
  puts(List.append(xs, 3))
  puts(xs.push(9))
end
```

```output
[1, 2, 3]
[1, 2, 9]
```

## set

```text
List.set(list: List[T], index: Int, value: T) -> List[T]
```

Replaces one element. A bad index stops the program.

```agentica
def main() -> Void
  puts(["a", "b", "c"].set(1, "B"))
end
```

```output
["a", "B", "c"]
```

## concat

```text
List.concat(a: List[T], b: List[T]) -> List[T]
```

```agentica
def main() -> Void
  puts([1, 2].concat([3]))
end
```

```output
[1, 2, 3]
```

## repeat

```text
List.repeat(value: T, count: Int) -> List[T]
```

```agentica
def main() -> Void
  puts(List.repeat("-", 3))
end
```

```output
["-", "-", "-"]
```

## reverse

```text
List.reverse(list: List[T]) -> List[T]
```

```agentica
def main() -> Void
  puts([1, 2, 3].reverse)
end
```

```output
[3, 2, 1]
```

## take and drop

```text
List.take(list: List[T], count: Int) -> List[T]
List.drop(list: List[T], count: Int) -> List[T]
```

`take` keeps the first `count` elements; `drop` removes them. A count larger
than the list is fine.

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.take(2))
  puts(xs.drop(2))
  puts(xs.take(10))
end
```

```output
[1, 2]
[3, 4]
[1, 2, 3, 4]
```

## sort

```text
List.sort(list: List[T]) -> List[T]
```

Sorts `Int`, `Float` or `String` values from small to large. Strings sort by
Unicode code, so `"B"` comes before `"a"`.

```agentica
def main() -> Void
  puts([3, 1, 2].sort)
  puts(["pear", "Fig", "apple"].sort)
end
```

```output
[1, 2, 3]
["Fig", "apple", "pear"]
```

## sort_by

```text
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]
```

Sorts by the key the function gives. The key is an `Int`, `Float` or `String`.
Equal keys keep their order.

```agentica
def main() -> Void
  words = ["ccc", "a", "bb"]
  puts(words.sort_by do |w| w.length end)
end
```

```output
["a", "bb", "ccc"]
```

## map

```text
List.map(list: List[A], f: Fn[A, B]) -> List[B]
```

```agentica
def main() -> Void
  puts([1, 2, 3].map do |x| x * 10 end)
  puts(["a", "b"].map do |s| s.upcase end)
end
```

```output
[10, 20, 30]
["A", "B"]
```

## filter

```text
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
```

Keeps the elements for which the function gives `true`.

```agentica
def main() -> Void
  puts([1, 2, 3, 4].filter do |x| x % 2 == 1 end)
end
```

```output
[1, 3]
```

## reduce

```text
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B
```

Combines the elements from left to right, starting with `initial`.

```agentica
def main() -> Void
  puts([1, 2, 3].reduce(0) do |sum, x| sum + x end)
  puts(["a", "b"].reduce("") do |text, s| text + s + s end)
end
```

```output
6
aabb
```

## each

```text
List.each(list: List[A], f: Fn[A, Void]) -> Void
```

Runs the function for each element, in order.

```agentica
def main() -> Void
  [1, 2].each do |x|
    puts("item #{x}")
  end
end
```

```output
item 1
item 2
```

## any? and all?

```text
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool
```

`any?` stops at the first `true`; `all?` stops at the first `false`.

```agentica
def main() -> Void
  xs = [3, 8, 5]
  puts(xs.any? do |x| x > 7 end)
  puts(xs.all? do |x| x > 7 end)
end
```

```output
true
false
```
