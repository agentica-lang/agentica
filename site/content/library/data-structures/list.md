---
title: List
weight: 1
description: Functions for List[T]. Each one is also a method on lists.
---

Lists are immutable: every function gives a new list. `xs.length` is `xs.size`, `push` is `append`, `select` is `filter`.

`xs == ys` is true when the two lists have the same length and equal items in the same order, compared in depth; the item type must have equality (not `Fn`, `Task`, `Channel`, a handle or `Json`).

A callback is a block, `&name` or a function variable. It runs once per element, left to right, under the caller's budget. The parameter and return types must match exactly, and a `map` callback returns data, not `Void`. Annotated block parameters let an empty list or an empty `reduce` initial value infer its type. The costs on this page leave out the callback's own work.

## Build and read

```signature
List.size(list: List[T]) -> Int
List.empty?(list: List[A]) -> Bool
List.at(list: List[T], index: Int) -> T
List.first(list: List[A]) -> A
List.last(list: List[A]) -> A
List.append(list: List[T], value: T) -> List[T]
List.set(list: List[T], index: Int, value: T) -> List[T]
List.concat(a: List[T], b: List[T]) -> List[T]
List.repeat(value: T, count: Int) -> List[T]
List.reverse(list: List[T]) -> List[T]
```

- `at` is `list[index]`, and `set` replaces one element. A bad index stops the program. Both are O(log32 n): at most four steps for a million items. A new list shares all but the path to the element.
- `first` and `last` give the first and the last element. On an empty list they stop the program with `RUNTIME-INDEX-OUT-OF-RANGE`, as `xs[0]` does; test with `empty?` first.
- `append` is near constant time, so n appends cost O(n). `reverse` is O(n).
- `repeat` takes a count from 0 to 1048576; zero gives an empty list of the element type, and any other count is `RUNTIME-INVALID-COUNT`.
- A negative or out-of-range index is `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument.
- `xs + ys` joins two lists of the same item type into a new one, as `concat` does; both lists stay as they were. It takes time in the size of `ys` when `ys` has 32 items or fewer. A longer `ys` copies both lists.

```agentica
def main() -> Void
  xs = [1, 2]
  puts(xs.size) # 2
  puts(xs.empty?) # false
  puts(xs.at(1)) # 2, the same as xs[1]
  puts(xs.first)
  puts(xs.last)
  puts(xs.push(9)) # xs is still [1, 2]
  puts(xs.set(0, 7))
  puts(xs + [3])
  puts(List.repeat("-", 3))
  puts(xs.reverse)
end
```

```output
2
false
2
1
2
[1, 2, 9]
[7, 2]
[1, 2, 3]
["-", "-", "-"]
[2, 1]
```

## take and drop

```signature
List.take(list: List[T], count: Int) -> List[T]
List.drop(list: List[T], count: Int) -> List[T]
```

`take` keeps the first `count` elements, `drop` removes them. A larger count gives the whole list (`take`) or an empty list (`drop`), and a negative count is `RUNTIME-INVALID-COUNT`. O(n) in the size of the result.

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.take(2))
  puts(xs.drop(2))
  puts(xs.take(10)) # a larger count is fine
end
```

```output
[1, 2]
[3, 4]
[1, 2, 3, 4]
```

## sort

```signature
List.sort(list: List[T]) -> List[T]
```

Sorts `Int`, `Float` or `String` values, smallest first; any other element type is `CHECK-TYPE-MISMATCH`. The sort is stable and O(n log n). Strings sort by code point, so `"B"` comes before `"a"`, and a `NaN` goes last.

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

```signature
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]
```

Sorts ascending by the key from the function (an `Int`, `Float` or `String`; any other key type is `CHECK-TYPE-MISMATCH`). The function runs once per element, left to right. Equal keys keep their order, and the cost is O(n log n) plus the key calls.

```agentica
def main() -> Void
  words = ["ccc", "a", "bb"]
  puts(words.sort_by do |w| w.length end)
end
```

```output
["a", "bb", "ccc"]
```

## map, select and reduce

```signature
List.map(list: List[A], f: Fn[A, B]) -> List[B]
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B
```

`select` (the function is `List.filter`) keeps the elements for which the function gives `true`. `reduce` combines from left to right, starting with `initial`.

```agentica
def main() -> Void
  puts([1, 2, 3].map do |x| x * 10 end)
  puts([1, 2, 3, 4].select do |x| x % 2 == 1 end)
  puts([1, 2, 3].reduce(0) do |sum, x| sum + x end)
end
```

```output
[10, 20, 30]
[1, 3]
6
```

## each and each_with_index

```signature
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void
```

Run the function for each element, in order, and give nothing back. The index starts at 0.

```agentica
def main() -> Void
  ["a", "b"].each_with_index do |s, i| puts("#{i}: #{s}") end
end
```

```output
0: a
1: b
```

## any? and all?

```signature
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

```signature
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

## index and find_index

```signature
List.index(list: List[T], value: T) -> Optional[Int]
List.find_index(list: List[A], f: Fn[A, Bool]) -> Optional[Int]
```

`index` gives `some` with the position of the first item `==` the value, else `none`; the items need `==`, as for `include?`. `find_index` takes a block instead and gives the position of the first element for which it gives `true`, so it is the block form: `xs.index do ... end` is `CHECK-BLOCK-TARGET`. Floats compare with `==`, so a NaN never matches (`[nan].index(nan)` is `none`) and `-0.0` matches `0.0`. Both stop at the first match and are O(n).

```agentica
def main() -> Void
  xs = ["pear", "fig", "fig"]
  puts(xs.index("fig"))
  puts(xs.index("kiwi"))
  puts(xs.find_index do |x| x.length > 3 end)
end
```

```output
some(1)
none
some(0)
```

## flat_map

```signature
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

```signature
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

```signature
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

```signature
List.each_slice(list: List[A], size: Int) -> List[List[A]]
```

Splits the list into slices of `size` elements; the last may be shorter. It takes no block (`CHECK-BLOCK-TARGET`): call `each` on the result. A `size` below 1 is `RUNTIME-INVALID-COUNT`.

```agentica
def main() -> Void
  [1, 2, 3, 4, 5].each_slice(2).each do |pair| puts(pair) end
end
```

```output
[1, 2]
[3, 4]
[5]
```

## group_by

```signature
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]
```

Groups by the key (an `Int` or a `String`; another key type is `CHECK-TYPE-MISMATCH` at the block). Keys and groups keep their first-appearance order.

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

```signature
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

## include?

```text
List.include?(list: List[T], value: T) -> Bool
```

True when an item `==` the value; `member?` is the same method. Items are any type that has `==` (numbers, `Bool`, `String`, `nil`, ranges, `Bytes`, and lists, maps, sets, Optionals, Results, structs and enums of those); a list of functions, `Json` or handles is `CHECK-TYPE-MISMATCH` at the list, and a value of another type is one at the value. It stops at the first match and is O(n). A `Float` follows IEEE 754, so `NaN` is never a member and `-0.0` matches `0.0`. For many lookups in one list, build a `Set` first.

```agentica
def main() -> Void
  puts(["pear", "fig"].include?("fig"))
  puts([3, 1, 2].member?(9))
end
```

```output
true
false
```

## sum

```signature
List.sum(list: List[N]) -> N
```

Adds `Int` or `Float` values from the left. An empty list gives `0` or `0.0`. An `Int` sum past 64 bits is `RUNTIME-INTEGER-OVERFLOW` at the call, and any other item type is `CHECK-TYPE-MISMATCH`.

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

## min and max

```signature
List.min(list: List[T]) -> Optional[T]
List.max(list: List[T]) -> Optional[T]
```

`some` with the least or greatest item, or `none` for an empty list. The items are `Int`, `Float` or `String` (compared with `String.compare`); any other item type is `CHECK-TYPE-MISMATCH`. The first item wins a tie, and a `NaN` never wins unless all are `NaN`. An `Int` has no `min(other)`, as in Ruby: write `[a, b].min.unwrap!`, or `n.clamp(lo, hi)` to keep a number in a range.

```agentica
def main() -> Void
  puts([3, 1, 2].min)
  puts([3, 1, 2].max)
  puts(["pear", "apple"].min)
  empty: List[Float] = []
  puts(empty.max)
  puts([700, 80].min.unwrap!)
end
```

```output
some(1)
some(3)
some("apple")
none
80
```

## min_by and max_by

```signature
List.min_by(list: List[A], key: Fn[A, O]) -> Optional[A]
List.max_by(list: List[A], key: Fn[A, O]) -> Optional[A]
```

`some` with the element of least or greatest key, or `none` for an empty list, as `min` and `max` give. The key is an `Int`, `Float` or `String` (compared with `String.compare`); the function runs once per element. The first element wins a tie, and a `NaN` key never wins unless all are `NaN`.

```agentica
def main() -> Void
  words = ["fig", "apple", "kiwi", "pear"]
  puts(words.min_by do |w| w.length end)
  puts(words.max_by do |w| w.length end)
  puts(words.max_by do |w| w end)
end
```

```output
some("fig")
some("apple")
some("pear")
```

## Costs and names

These are O(n), less when they stop early. They are written in Agentica (`stdlib/prelude/`), so they count `--max-steps` per element, not counting your function, and a runtime error in one is reported at the call in your program (at the argument it names), never in the prelude.

`reject` is `CHECK-UNKNOWN-METHOD`. Write `xs.select do |x| !cond end`.
