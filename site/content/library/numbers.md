---
title: Int and Float
weight: 4
description: Convert between Int, Float and String.
---

Arithmetic never mixes `Int` and `Float`. Use these functions to convert.

| Method | Same as |
|---|---|
| `n.to_s` on an `Int` | `String.from_int(n)` |
| `n.to_f` on an `Int` | `Float.from_int(n)` |
| `x.to_s` on a `Float` | `String.from_float(x)` |
| `x.to_i`, `x.to_i!` on a `Float` | `Float.to_int(x)`, `Float.to_int!(x)` |

To read numbers from text, see [to_int and to_float](/library/string/#to_int-and-to_float).
For the loop methods `n.times`, `a.upto(b)` and `a.downto(b)`, see
[Range](/library/range/#times-upto-and-downto).

## Float.from_int

```text
Float.from_int(n: Int) -> Float
```

```agentica
def main() -> Void
  n = 3
  puts(Float.from_int(n) / 2.0)
  puts(n.to_f)
end
```

```output
1.5
3.0
```

## Float.to_int

```text
Float.to_int(x: Float) -> Result[Int]
```

Cuts off the decimals, toward zero. A value that does not fit in an `Int`, or
that is not a number, gives an error Result.

```agentica
def main() -> Void
  puts(Float.to_int(2.9))
  puts((-2.9).to_i)
  puts(Float.to_int(10000000000.0 * 10000000000.0).ok?)
end
```

```output
ok(2)
ok(-2)
false
```

## Float.to_int!

```text
Float.to_int!(x: Float) -> Int
```

Like `Float.to_int`, but gives the `Int` itself and stops the program on a bad
value.

```agentica
def main() -> Void
  puts(Float.to_int!(7.5) + 1)
  puts(9.99.to_i!)
end
```

```output
8
9
```

## Int to text

```agentica
def main() -> Void
  n = 42
  puts(n.to_s + "!")
  puts(2.5.to_s + "!")
end
```

```output
42!
2.5!
```
