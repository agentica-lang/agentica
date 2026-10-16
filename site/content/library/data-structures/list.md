---
title: List
weight: 1
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

The same as `list[index]`. A bad index stops the program. It takes O(log32 n) time, at most four steps for a million items.

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

Adds a value at the end. `push` is the method alias. It takes near constant time, so a loop of n pushes costs O(n) in total, and the old list stays as it was.

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

Replaces one element. A bad index stops the program. It takes O(log32 n) time and shares everything but the path to the element with the old list.

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

Joining a list of 32 items or fewer takes time in the size of the right list. A longer right list copies both lists.

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
than the list is fine. Both copy the elements they keep, so they cost O(n).

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

## find

```text
List.find(list: List[A], f: Fn[A, Bool]) -> Result[A]
```

Gives `ok` with the first element for which the function gives `true`, or
`error("not found")`. It stops calling the function at the first match.

```agentica
def main() -> Void
  xs = [3, 8, 5, 9]
  puts(xs.find do |x| x > 4 end)
  puts(xs.find do |x| x > 10 end)
end
```

```output
ok(8)
error("not found")
```

## each_with_index

```text
List.each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void
```

Runs the function with each element and its index, which starts at 0.

```agentica
def main() -> Void
  ["a", "b"].each_with_index do |s, i|
    puts("#{i}: #{s}")
  end
end
```

```output
0: a
1: b
```

## flat_map

```text
List.flat_map(list: List[A], f: Fn[A, List[B]]) -> List[B]
```

Joins the lists the function gives, in order.

```agentica
def main() -> Void
  puts([1, 2, 3].flat_map do |x| List.repeat(x, x) end)
end
```

```output
[1, 2, 2, 3, 3, 3]
```

## partition

```text
List.partition(list: List[A], f: Fn[A, Bool]) -> List[List[A]]
```

Gives `[accepted, rejected]`: the elements for which the function gives `true`,
then the others, each in order.

```agentica
def main() -> Void
  halves = [1, 2, 3, 4, 5].partition do |x| x % 2 == 0 end
  puts(halves[0])
  puts(halves[1])
end
```

```output
[2, 4]
[1, 3, 5]
```

## take_while and drop_while

```text
List.take_while(list: List[A], f: Fn[A, Bool]) -> List[A]
List.drop_while(list: List[A], f: Fn[A, Bool]) -> List[A]
```

`take_while` keeps the elements before the first one for which the function
gives `false`; `drop_while` keeps that one and the rest. Neither calls the
function after that first `false`.

```agentica
def main() -> Void
  xs = [1, 2, 5, 1]
  puts(xs.take_while do |x| x < 3 end)
  puts(xs.drop_while do |x| x < 3 end)
end
```

```output
[1, 2]
[5, 1]
```

## each_slice

```text
List.each_slice(list: List[A], size: Int) -> List[List[A]]
```

Splits the list into slices of `size` elements; the last one may be shorter.
It has no block: a block after it is `CHECK-BLOCK-TARGET`. To walk the slices,
call `each` on the result. A `size` below 1 is `RUNTIME-INVALID-COUNT`.

```agentica
def main() -> Void
  [1, 2, 3, 4, 5].each_slice(2).each do |pair|
    puts(pair)
  end
end
```

```output
[1, 2]
[3, 4]
[5]
```

## group_by

```text
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]
```

Groups the elements by the key the function gives, which is an `Int` or a
`String`. The map lists the keys in the order they first appear, and each group
keeps the order of its elements.

```agentica
def main() -> Void
  words = ["apple", "fig", "pear", "kiwi"]
  puts(words.group_by do |w| w.length end)
end
```

```output
{5: ["apple"], 3: ["fig"], 4: ["pear", "kiwi"]}
```

## tally and uniq

```text
List.tally(list: List[K]) -> Map[K, Int]
List.uniq(list: List[K]) -> List[K]
```

`tally` counts equal items and `uniq` keeps the first of each. The items are
`Int` or `String`. The order is the order of first appearance.

```agentica
def main() -> Void
  xs = ["b", "a", "b"]
  puts(xs.tally)
  puts(xs.uniq)
end
```

```output
{"b": 2, "a": 1}
["b", "a"]
```

## sum

```text
List.sum(list: List[N]) -> N
```

Adds a list of `Int` or `Float` from the left. An empty list gives `0` or
`0.0`. An `Int` sum that leaves 64 bits is `RUNTIME-INTEGER-OVERFLOW`.

```agentica
def main() -> Void
  puts([1, 2, 3].sum)
  puts([0.5, 0.25].sum)
end
```

```output
6
0.75
```

## min_by and max_by

```text
List.min_by(list: List[A], key: Fn[A, O]) -> Result[A]
List.max_by(list: List[A], key: Fn[A, O]) -> Result[A]
```

Give `ok` with the element that has the least or the greatest key, or
`error("the list is empty")`. The key is an `Int`, `Float` or `String`, and the
function runs once for each element. The first element wins a tie. A `NaN` key
never wins, unless every key is `NaN`. `String` keys compare with
`String.compare`.

```agentica
def main() -> Void
  words = ["fig", "apple", "kiwi", "pear"]
  puts(words.min_by do |w| w.length end)
  puts(words.max_by do |w| w.length end)
  puts(words.max_by do |w| w end)
end
```

```output
ok("fig")
ok("apple")
ok("pear")
```

## Costs and names

All of these take O(n) time in the length of the list, except the ones that
stop early. They are written in Agentica (`stdlib/prelude/`), so they count the
program's steps: `find` costs 4 steps for each element it looks at, `sum` 4,
`tally` about 10, `min_by` about 20 and `group_by` about 14, not counting the
function you give.

Each method has one name. `select`, `collect`, `detect`, `inject` and `reject`
are `CHECK-UNKNOWN-METHOD`: use `filter`, `map`, `find` and `reduce`, and
`xs.filter do |x| !cond end` for `reject`.
