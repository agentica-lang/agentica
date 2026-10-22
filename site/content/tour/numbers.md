---
title: Numbers
weight: 4
description: Int and Float, arithmetic, comparison and conversion.
---

## Int and Float

`Int` holds whole numbers of 64 bits. `Float` holds decimal numbers.

```agentica
def main() -> Void
  puts(7 + 3)
  puts(7 - 10)
  puts(7 * 3)
  puts(1.5 + 2.25)
end
```

```output
10
-3
21
3.75
```

## Long numbers

A `_` between digits is only visual: `1_000` is the same `Int` as `1000`.

```agentica
def main() -> Void
  budget = 1_000_000
  rate = 0.000_5
  puts(budget)
  puts(rate)
  puts(1_000 == 1000)
end
```

```output
1000000
0.0005
true
```

`1_`, `1__0`, `1_.5` and `1._5` are `LEX-INVALID-NUMBER`. `s.to_i` and `s.to_f` reject a `_` in text.

## Division

`/` on two `Int` values cuts off the decimals, toward zero. `%` is the remainder and works on `Int` only.

```agentica
def main() -> Void
  puts(7 / 2)
  puts(-7 / 2)
  puts(7 % 2)
  puts(7.0 / 2.0)
end
```

```output
3
-3
1
3.5
```

Dividing by zero stops the program with an error, also for `Float`:

```agentica {expect="RUNTIME-DIVISION-BY-ZERO"}
def main() -> Void
  zero = 0
  puts(10 / zero)
end
```

## Mixing Int and Float

The two sides of an operator must have the same type. Convert with `to_f` or `to_i!`.

```agentica
def main() -> Void
  count = 3
  price = 2.5
  puts(count.to_f * price)
  puts(7.9.to_i!)
end
```

```output
7.5
7
```

## Comparison

`<`, `<=`, `>` and `>=` compare two numbers of the same type. `==` and `!=` work on numbers, `Bool`, `String` and `nil`.

```agentica
def main() -> Void
  puts(3 < 5)
  puts(2.5 >= 2.5)
  puts(4 == 4)
  puts(4 != 5)
end
```

```output
true
true
true
true
```

Comparisons do not chain. Write `a < b and b < c`:

```agentica
def main() -> Void
  n = 5
  puts(1 < n and n < 10)
end
```

```output
true
```

## Negative numbers

A minus sign is an operator. Use parentheses to call a method on a negative literal:

```agentica
def main() -> Void
  puts((-5).to_s + " degrees")
end
```

```output
-5 degrees
```

## Text to numbers

`to_i` and `to_f` read a number from a string. They give a [Result](/tour/results-and-try/), because the text may not be a number. `to_i!` and `to_f!` give the number and stop the program on bad text.

```agentica
def main() -> Void
  puts("42".to_i)
  puts("4x".to_i)
  puts("42".to_i! + 1)
  puts("2.5".to_f!)
end
```

```output
ok(42)
error("cannot convert \"4x\" to Int")
43
2.5
```

## Overflow

`Int` overflow is an error. It never wraps around.

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  big = 9223372036854775807
  puts(big + 1)
end
```

See [Int and Float](/library/text-and-data/numbers/) for all conversion functions.
