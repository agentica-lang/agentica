---
title: Range
weight: 5
description: Ranges of Int values, and the Int loop methods times, upto and downto.
---

`a..b` includes both ends; `a...b` leaves `b` out. Both ends are `Int`, and the type is `Range`. A range stores only its start, end and kind, so `0...1000000000` costs nothing until used. An end that is not `Int` is `CHECK-TYPE-MISMATCH`, as in `"a"..."c"`.

`for` walks a range in order. An empty range (end before start) does nothing. Counting up to the largest `Int` does not overflow.

```agentica
def main() -> Void
  for i in 0...3
    puts(i)
  end

  for i in 3..1
    puts("never")
  end
end
```

```output
0
1
2
```

Ranges bind looser than every other operator, so `0...n + 1` is `0...(n + 1)`. A method call on a range needs parentheses: `(1..5).to_a`. A range prints as `1..5` or `1...5`, and two ranges are equal when their start, end and kind match. `select`, `collect`, `detect` and `inject` on a range are `CHECK-UNKNOWN-METHOD`.

```agentica
def main() -> Void
  r = 1...5
  puts(r)
  puts(r == (1...5))
  puts(r == (1..5))
end
```

```output
1...5
true
false
```

## size

```text
Range.size(range: Range) -> Int
```

The number of values. A count that does not fit in `Int`, as for `(0..9223372036854775807).size`, stops the program.

```agentica
def main() -> Void
  puts((1..5).size)
  puts((1...5).size)
  puts((5..1).size)
end
```

```output
5
4
0
```

## to_a

```text
Range.to_a(range: Range) -> List[Int]
```

The values as a list, in order. A range with more than 1048576 values stops the program.

```agentica
def main() -> Void
  evens = (0..10).to_a.select do |n|
    n % 2 == 0
  end

  puts(evens)
end
```

```output
[0, 2, 4, 6, 8, 10]
```

## include?

```text
Range.include?(range: Range, value: Int) -> Bool
```

```agentica
def main() -> Void
  puts((1...5).include?(4))
  puts((1...5).include?(5))
end
```

```output
true
false
```

## each

```text
Range.each(range: Range, f: Fn[Int, Void]) -> Void
```

Calls the block with each value, in order.

```agentica
def main() -> Void
  (1..3).each do |i|
    puts(i * 10)
  end
end
```

```output
10
20
30
```

## first and last

```text
Range.first(range: Range) -> Result[Int]
Range.last(range: Range) -> Result[Int]
```

The first and the last included value, or an error for an empty range. Unlike Ruby, `(1...5).last` is `ok(4)`.

```agentica
def main() -> Void
  puts((1...5).first)
  puts((1...5).last)
  puts((5..1).last)
end
```

```output
ok(1)
ok(4)
error("the range is empty")
```

## times, upto and downto

```text
Int.times(n: Int, f: Fn[Int, Void]) -> Void
Int.upto(from: Int, to: Int, f: Fn[Int, Void]) -> Void
Int.downto(from: Int, to: Int, f: Fn[Int, Void]) -> Void
```

Methods on `Int` for loops. `n.times` calls the block with `0` to `n - 1`, and nothing when `n <= 0`. `a.upto(b)` counts from `a` up to `b`, and `a.downto(b)` from `a` down to `b`, both ends included; they do nothing when the end is already past. A negative receiver needs parentheses: `(-2).upto(2)`.

```agentica
def main() -> Void
  3.times do |i|
    print(i)
  end

  puts("")
  1.upto(3) do |i|
    print(i)
  end

  puts("")
  3.downto(1) do |i|
    print(i)
  end

  puts("")
end
```

```output
012
123
321
```
