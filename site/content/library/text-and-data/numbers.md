---
title: Int and Float
weight: 2
description: Convert between Int, Float and String, and work on the bits of an Int or a Float.
---

Arithmetic never mixes `Int` and `Float`. Use these functions to convert.

| Method | Same as |
|---|---|
| `n.to_s` on an `Int` | `String.from_int(n)` |
| `n.to_f` on an `Int` | `Float.from_int(n)` |
| `x.to_s` on a `Float` | `String.from_float(x)` |
| `x.to_i`, `x.to_i!` on a `Float` | `Float.to_int(x)`, `Float.to_int!(x)` |

The bit functions work on the 64-bit two's complement form of an `Int` (`Int.bit_and`, `Int.shift_left` and the others) and on the IEEE 754 bits of a `Float` (`Float.to_bits` and the others).
They are methods too: `flags.bit_and(4)`, `x.to_bits`.
The core has no hex literals, so write masks in decimal (`255`, `65535`).

To read numbers from text, see [to_int and to_float](/library/text-and-data/string/#to_int-and-to_float).
For the loop methods `n.times`, `a.upto(b)` and `a.downto(b)`, see
[Range](/library/data-structures/range/#times-upto-and-downto).

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

## Int.bit_and, Int.bit_or and Int.bit_xor

```text
Int.bit_and(a: Int, b: Int) -> Int
Int.bit_or(a: Int, b: Int) -> Int
Int.bit_xor(a: Int, b: Int) -> Int
Int.bit_not(a: Int) -> Int
```

Combine the bits of two numbers, bit by bit.
They never fail.
`Int.bit_not(a)` flips every bit and is the same as `-1 - a`.
A negative number has its sign bit set, so `Int.bit_and(-1, 255)` is `255`.

```agentica
def main() -> Void
  flags = 5
  puts(flags.bit_and(4) == 4)
  puts(Int.bit_or(12, 10))
  puts(Int.bit_xor(12, 10))
  puts(Int.bit_not(0))
  puts(Int.bit_and(-1, 255))
end
```

```output
true
14
6
-1
255
```

## Int.shift_left, Int.shift_right and Int.shift_right_unsigned

```text
Int.shift_left(a: Int, count: Int) -> Int
Int.shift_right(a: Int, count: Int) -> Int
Int.shift_right_unsigned(a: Int, count: Int) -> Int
```

`shift_left` moves the bits up.
Bits that leave the top are dropped and bit 63 becomes the sign, so it wraps instead of failing: `1.shift_left(63)` is `-9223372036854775808`.
Multiply (`x * 2`) when you want the overflow check.

`shift_right` is arithmetic: copies of the sign bit come in at the top.
It is `a / 2^count` rounded down, toward minus infinity, where `/` truncates toward zero.

`shift_right_unsigned` is logical: zeros come in at the top, so it reads `a` as an unsigned 64-bit number.
`(-1).shift_right_unsigned(64 - n)` is a mask of the low `n` bits for every `n` from 0 to 64.

A count of 64 or more shifts every bit out: `shift_left` and `shift_right_unsigned` give `0`, and `shift_right` gives `0` or `-1` by the sign of `a`.
A negative count is `RUNTIME-INVALID-COUNT` at the count.

```agentica
def main() -> Void
  puts(3.shift_left(8))
  puts((-1).shift_left(1))
  puts((-7).shift_right(1))
  puts((-7) / 2)
  puts((-1).shift_right_unsigned(60))
  puts((-1).shift_right_unsigned(64 - 8))
  puts(1.shift_left(64))
  puts((-5).shift_right(100))
  puts(7.shift_right(1).bit_and(1) == 1)
end
```

```output
768
-2
-4
-3
15
255
0
-1
true
```

```agentica {expect="RUNTIME-INVALID-COUNT"}
def main() -> Void
  puts(1.shift_left(0 - 1))
end
```

## Float.to_bits and Float.from_bits

```text
Float.to_bits(x: Float) -> Int
Float.from_bits(bits: Int) -> Float
```

`to_bits` gives the IEEE 754 binary64 bits of `x` as an `Int`, so a `Float` with the sign bit set gives a negative `Int`.
Every NaN gives the one quiet NaN, `9221120237041090560`, so every platform agrees.
`x.to_bits < 0` tests the sign bit of every value except NaN; test NaN with `x != x`.
`-0.0 == 0.0` is true, but their bits differ, so `to_bits` tells the two zeros apart.

`from_bits` takes every `Int` and reads its 64 bits as a binary64.
Subnormals, infinities and `-0.0` come back exactly, and any NaN pattern gives NaN.
So `Float.to_bits(Float.from_bits(n)) == n` for every `n` except NaN patterns other than the quiet NaN.

```agentica
def main() -> Void
  puts(Float.to_bits(1.0))
  puts(Float.to_bits(-2.0))
  puts((0.0 - 1.0) * 0.0 == 0.0)
  puts(((0.0 - 1.0) * 0.0).to_bits)
  puts(Float.from_bits(4607182418800017408))
  puts(Float.from_bits(1) > 0.0)
  puts(Float.from_bits(Float.to_bits(0.1)) == 0.1)
end
```

```output
4607182418800017408
-4611686018427387904
true
-9223372036854775808
1.0
true
true
```

## Float.to_bits32 and Float.from_bits32

```text
Float.to_bits32(x: Float) -> Int
Float.from_bits32(bits: Int) -> Float
```

`to_bits32` rounds `x` to binary32, to nearest with ties to even, and gives its 32 bits as an `Int` from 0 to 4294967295.
A value too large for binary32 becomes infinity with the same sign, a very small one rounds to a subnormal or to zero and keeps its sign, and every NaN gives `2143289344`.

`from_bits32` reads 32 bits as a binary32 and widens it to a `Float`, which is always exact.
Any other `Int` is `RUNTIME-INVALID-NUMBER` at the argument.
So `Float.to_bits32(Float.from_bits32(n)) == n` for every `n` except NaN patterns other than `2143289344`.

```agentica
def main() -> Void
  puts(Float.to_bits32(1.0))
  puts(Float.to_bits32(0.1))
  puts(Float.from_bits32(1036831949))
  puts(Float.from_bits32(1065353216))
  puts(Float.to_bits32(Float.from_bits32(2143289345)))
end
```

```output
1065353216
1036831949
0.10000000149011612
1.0
2143289344
```

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Float.from_bits32(4294967296))
end
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
