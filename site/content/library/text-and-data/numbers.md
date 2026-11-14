---
title: Int and Float
weight: 2
description: Convert between Int, Float and String, round, clamp and other number helpers, and work on the bits of an Int or a Float.
---

Arithmetic never mixes `Int` and `Float`. Use these methods to convert: `n.to_f`, `x.to_i` and `x.to_i!`, and `to_s` for the text.

The bit functions work on the 64-bit two's complement form of an `Int` (`Int.bit_and`, `Int.shift_left` and the others) and on the IEEE 754 bits of a `Float` (`Float.to_bits` and the others). They are methods too: `flags.bit_and(4)`, `x.to_bits`. Masks read best in hex or binary: `0xFF`, `0b1010` (see [hex, binary and octal](/tour/numbers/#hex-binary-and-octal)).

The number helpers are methods, as in Ruby: `n.abs`, `n.pow(3)`, `a.gcd(b)`, `n.clamp(lo, hi)`, `x.floor`, `x.ceil`, `x.round`, and `Math.sqrt(x)`. There is no `**` operator. For the least or greatest item of a list, see [min and max](/library/data-structures/list/#min-and-max).

To read numbers from text, see [to_i and to_f](/library/text-and-data/string/#to_i-and-to_f). For the loop methods `n.times`, `a.upto(b)` and `a.downto(b)`, see [Range](/library/data-structures/range/#times-upto-and-downto).

## to_s

```signature
Int.to_s(int: Int) -> String
Float.to_s(float: Float) -> String
```

The text of a number, as `puts` and interpolation write it.

```agentica
def main() -> Void
  puts(42.to_s + "!")
  puts(2.5.to_s + "!")
end
```

```output
42!
2.5!
```

## to_f

```signature
Int.to_f(int: Int) -> Float
```

```agentica
def main() -> Void
  n = 3
  puts(n.to_f / 2.0)
  puts(n.to_f)
end
```

```output
1.5
3.0
```

## to_i

```signature
Float.to_i(float: Float) -> Result[Int]
```

Cuts off the decimals, toward zero. A value that does not fit in an `Int`, or that is not a number (NaN or an infinity), gives an error Result.

```agentica
def main() -> Void
  puts(2.9.to_i)
  puts((-2.9).to_i)
  puts((10000000000.0 * 10000000000.0).to_i.ok?)
end
```

```output
ok(2)
ok(-2)
false
```

## to_i!

```signature
Float.to_i!(float: Float) -> Int
```

Like `to_i`, but gives the `Int` itself and stops the program on a bad value, with `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`.

```agentica
def main() -> Void
  puts(7.5.to_i! + 1)
  puts(9.99.to_i!)
end
```

```output
8
9
```

## abs, pow and gcd

```signature
Int.abs(int: Int) -> Int
Float.abs(float: Float) -> Float
Int.pow(int: Int, exponent: Int) -> Int
Int.gcd(int: Int, other: Int) -> Int
```

- `abs` of the least `Int`, `-9223372036854775808`, does not fit and is `RUNTIME-INTEGER-OVERFLOW`, as `-n` is. `Float.abs` clears the sign, so `-0.0` gives `0.0`, and a NaN stays NaN.
- `n.pow(e)` is `n` to the power `e`; `n.pow(0)` is `1`, `0.pow(0)` too. A result past 64 bits is `RUNTIME-INTEGER-OVERFLOW` at the call. A negative exponent is `RUNTIME-INVALID-COUNT` at the exponent: Ruby gives a fraction there, which an `Int` cannot hold.
- `gcd` is never negative, and `0.gcd(0)` is `0`. The only result that does not fit is `2^63`, from the least `Int` with `0` or with itself: `RUNTIME-INTEGER-OVERFLOW`.

```agentica
def main() -> Void
  puts((-5).abs)
  puts((-2.5).abs)
  puts(2.pow(10))
  puts((-3).pow(3))
  puts(12.gcd(18))
  puts((-12).gcd(0))
end
```

```output
5
2.5
1024
-27
6
12
```

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  puts(2.pow(63))
end
```

## clamp

```signature
Int.clamp(int: Int, min: Int, max: Int) -> Int
Float.clamp(float: Float, min: Float, max: Float) -> Float
```

Gives `min` when the number is below it, `max` when above it, and the number itself otherwise. `min > max` stops the program with `RUNTIME-INVALID-RANGE`, as in Ruby (an `ArgumentError` there). On a `Float`, a NaN bound is `RUNTIME-INVALID-RANGE` too, and a NaN `float` comes back as NaN.

```agentica
def main() -> Void
  requested = 2000
  puts(requested.clamp(1, 512))
  puts((-4).clamp(0, 10))
  puts(1.5.clamp(0.0, 1.0))
end
```

```output
512
0
1.0
```

```agentica {expect="RUNTIME-INVALID-RANGE"}
def main() -> Void
  puts(5.clamp(10, 1))
end
```

## floor, ceil and round

```signature
Float.floor(float: Float) -> Int
Float.ceil(float: Float) -> Int
Float.round(float: Float) -> Int
```

They give an `Int`, as Ruby's `Float#floor` gives an `Integer`. `floor` goes down, `ceil` goes up, and `round` goes to the nearest whole number, with halves away from zero: `2.5.round` is `3` and `(-2.5).round` is `-3`. Like `x.to_i!`, NaN or an infinity is `RUNTIME-INVALID-NUMBER` and a result outside `Int` is `RUNTIME-INTEGER-OVERFLOW`. `round` takes no number of digits; [`format("%.2f", x)`](#format) writes a Float with two digits after the point.

```agentica
def main() -> Void
  puts(2.7.floor)
  puts((-2.1).floor)
  puts(2.1.ceil)
  puts(2.5.round)
  puts((-2.5).round)
  puts((3.14159 * 100.0).round.to_f / 100.0)
end
```

```output
2
-3
3
3
-3
3.14
```

## format

```signature
format(format: String, args...) -> String
```

The text of a format string with one argument for each conversion, as Ruby's `format`. A conversion is `%[flags][width][.precision]type`:

- `d`: an `Int` in decimal.
- `x`: an `Int` in lowercase hex; a negative number is `-` and the hex of its magnitude (`-ff`).
- `f`: a `Float` in fixed point, with 6 digits after the point unless `.precision` (0 to 50) says otherwise. It rounds the exact binary value, as C and Ruby do: `format("%.2f", 2.675)` is `2.67`, since `2.675` is a little below it. NaN, `Inf` and `-Inf` are written as in Ruby.
- `s`: any value with `to_s`, as `puts` writes it.
- `%%` is a `%`.

The flag `0` pads a number with zeros after its sign, and `-` pads on the right with spaces; without a flag the padding is spaces on the left. `width` is 1 to 1000 and counts characters, as `String.length` does. An `Int` for `%f` is not converted: write `n.to_f`.

The format must be a `"..."` string literal on one line, which the checker reads: a conversion it does not know (`%X`, `%e`, the flags `+`, space and `#`, a precision on `d`, `x` or `s`) is `CHECK-FORMAT-SPEC` at that conversion, another first argument is `CHECK-FORMAT-LITERAL`, the wrong number of arguments is `CHECK-ARITY`, and an argument of the wrong type is `CHECK-TYPE-MISMATCH`. A format whose conversions are all a plain `%s` or `%d` is `CHECK-FORMAT-SPEC` too: write `"#{x}"`.

```agentica
def main() -> Void
  puts(format("%-8s|%6.2f|%03d|%x", "apple", 2.5, 7, 255))
  puts(format("%05d|%-5d|%x", -42, 3, -255))
  puts(format("%.0f %.0f %.3f", 0.5, 1.5, 1.0 / 3.0))
  puts(format("%5.1f%%", 99.95))
end
```

```output
apple   |  2.50|007|ff
-0042|3    |-ff
0 2 0.333
100.0%
```

## Math.sqrt

```signature
Math.sqrt(float: Float) -> Float
```

The square root. A negative `float` stops the program with `RUNTIME-INVALID-NUMBER` at the argument, as Ruby raises `Math::DomainError`. `-0.0` gives `-0.0`, infinity gives infinity, and a NaN stays NaN. For an `Int`, convert first: `Math.sqrt(n.to_f)`.

```agentica
def main() -> Void
  puts(Math.sqrt(16.0))
  puts(Math.sqrt(2.0))
  puts(Math.sqrt(9.to_f).floor)
end
```

```output
4.0
1.4142135623730951
3
```

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Math.sqrt(0.0 - 1.0))
end
```

## Int.bit_and, Int.bit_or and Int.bit_xor

```signature
Int.bit_and(int: Int, other: Int) -> Int
Int.bit_or(int: Int, other: Int) -> Int
Int.bit_xor(int: Int, other: Int) -> Int
Int.bit_not(int: Int) -> Int
```

Combine the bits of two numbers, bit by bit. They never fail. `Int.bit_not(a)` flips every bit and is the same as `-1 - a`. A negative number has its sign bit set, so `Int.bit_and(-1, 255)` is `255`.

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

```signature
Int.shift_left(int: Int, count: Int) -> Int
Int.shift_right(int: Int, count: Int) -> Int
Int.shift_right_unsigned(int: Int, count: Int) -> Int
```

- `shift_left(int, count)` is the low 64 bits of `int * 2^count`: bits that leave the top are dropped and bit 63 becomes the sign, so `1.shift_left(63)` is `-9223372036854775808`. Use `x * 2` for an overflow check.
- `shift_right` is arithmetic (the sign bit comes in), so it rounds toward minus infinity: `(-7).shift_right(1)` is `-4`.
- `shift_right_unsigned` is logical (zeros come in): it reads `int` as an unsigned 64-bit number. `(-1).shift_right_unsigned(64 - n)` masks the low `n` bits.
- A count of 64 or more shifts every bit out: the result is `0`, or `-1` for `shift_right` of a negative `int`. A negative count is `RUNTIME-INVALID-COUNT`.

```agentica
def main() -> Void
  puts(3.shift_left(8))
  puts((-1).shift_left(1))
  puts((-7).shift_right(1))
  puts(-7 / 2)
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

```signature
Float.to_bits(float: Float) -> Int
Float.from_bits(bits: Int) -> Float
```

`to_bits` gives the IEEE 754 binary64 bits of `float` as a two's complement `Int` (`1.0` is `4607182418800017408`, `-0.0` is `-9223372036854775808`). Every NaN gives the quiet NaN `9221120237041090560`. `x.to_bits < 0` tests the sign bit of every value except NaN (test NaN with `x != x`), and `to_bits` tells `-0.0` from `0.0`.

`from_bits` reads the 64 bits of any `Int` as a binary64; subnormals, infinities and `-0.0` come back exactly, and any NaN pattern gives NaN. So `Float.to_bits(Float.from_bits(n)) == n` for every `n` except NaN patterns other than the quiet NaN.

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

```signature
Float.to_bits32(float: Float) -> Int
Float.from_bits32(bits: Int) -> Float
```

`to_bits32` rounds `float` to binary32, to nearest with ties to even, and gives its 32 bits as an `Int` from 0 to 4294967295. A magnitude of `2^128 - 2^103` or more becomes infinity with the same sign. A very small one rounds to a subnormal or to zero and keeps its sign. Every NaN gives `2143289344`.

`from_bits32` reads 32 bits as a binary32 and widens it to a `Float`, which is always exact. An `Int` outside `0 .. 4294967295` is `RUNTIME-INVALID-NUMBER` at the argument. So `Float.to_bits32(Float.from_bits32(n)) == n` for every `n` except NaN patterns other than `2143289344`.

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
