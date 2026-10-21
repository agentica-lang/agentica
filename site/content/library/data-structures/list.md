---
title: List
weight: 1
description: Functions for List[T]. Each one is also a method on lists.
---

Lists are immutable: every function gives a new list. `xs.length` is `xs.size`, `push` is `append`.

## Build and read

```text
List.size(list: List[T]) -> Int
List.at(list: List[T], index: Int) -> T
List.append(list: List[T], value: T) -> List[T]
List.set(list: List[T], index: Int, value: T) -> List[T]
List.concat(a: List[T], b: List[T]) -> List[T]
List.repeat(value: T, count: Int) -> List[T]
List.reverse(list: List[T]) -> List[T]
```

- `at` is `list[index]`, and `set` replaces one element. A bad index stops the program. Both are O(log32 n): at most four steps for a million items. A new list shares all but the path to the element.
- `append` is near constant time, so n appends cost O(n).
- `concat` takes time in the size of `b` when `b` has 32 items or fewer. A longer `b` copies both lists.

```agentica
def main() -> Void
  xs = [1, 2]
  puts(xs.size)                # 2
  puts(xs.at(1))               # 2, the same as xs[1]
  puts(xs.push(9))             # xs is still [1, 2]
  puts(xs.set(0, 7))
  puts(xs.concat([3]))
  puts(List.repeat("-", 3))
  puts(xs.reverse)
end
```

```output
2
2
[1, 2, 9]
[7, 2]
[1, 2, 3]
["-", "-", "-"]
[2, 1]
```

## take and drop

```text
List.take(list: List[T], count: Int) -> List[T]
List.drop(list: List[T], count: Int) -> List[T]
```

`take` keeps the first `count` elements, `drop` removes them. A larger count is fine. O(n).

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.take(2))
  puts(xs.drop(2))
  puts(xs.take(10))   # a larger count is fine
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

Sorts `Int`, `Float` or `String` values, smallest first. Strings sort by Unicode code, so `"B"` comes before `"a"`.

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

Sorts by the key from the function (an `Int`, `Float` or `String`). Equal keys keep their order.

```agentica
def main() -> Void
  words = ["ccc", "a", "bb"]
  puts(words.sort_by do |w| w.length end)
end
```

```output
["a", "bb", "ccc"]
```

## map, filter and reduce

```text
List.map(list: List[A], f: Fn[A, B]) -> List[B]
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B
```

`filter` keeps the elements for which the function gives `true`. `reduce` combines from left to right, starting with `initial`.

```agentica
def main() -> Void
  puts([1, 2, 3].map do |x| x * 10 end)
  puts([1, 2, 3, 4].filter do |x| x % 2 == 1 end)
  puts([1, 2, 3].reduce(0) do |sum, x| sum + x end)
end
```

```output
[10, 20, 30]
[1, 3]
6
```

## each and each_with_index

```text
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void
```

Run the function for each element, in order. The index starts at 0.

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

## any? and all?

```text
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool
```

`any?` stops at the first `true`, `all?` at the first `false`.

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

`ok` with the first element for which the function gives `true`, else `error("not found")`. It stops at the first match.

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

Gives `[accepted, rejected]`.

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

`take_while` keeps the elements before the first `false`; `drop_while` keeps that one and the rest. Neither calls the function after it.

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

Splits the list into slices of `size` elements; the last may be shorter. It takes no block (`CHECK-BLOCK-TARGET`): call `each` on the result. A `size` below 1 is `RUNTIME-INVALID-COUNT`.

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

Groups by the key (an `Int` or a `String`). Keys and groups keep their first-appearance order.

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

`tally` counts equal items; `uniq` keeps the first of each. Items are `Int` or `String`, in order of first appearance.

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

Adds `Int` or `Float` values from the left. An empty list gives `0` or `0.0`. An `Int` sum past 64 bits is `RUNTIME-INTEGER-OVERFLOW`.

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

`ok` with the element of least or greatest key, else `error("the list is empty")`. The key is an `Int`, `Float` or `String` (compared with `String.compare`); the function runs once per element. The first element wins a tie, and a `NaN` key never wins unless all are `NaN`.

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

These are O(n), less when they stop early. They are written in Agentica (`stdlib/prelude/`), so they count `--max-steps` per element, not counting your function.

Each method has one name: `select`, `collect`, `detect`, `inject` and `reject` are `CHECK-UNKNOWN-METHOD`. Use `filter`, `map`, `find`, `reduce` and `xs.filter do |x| !cond end`.
