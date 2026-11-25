---
title: Int and Float
weight: 2
description: Convert between Int, Float, Float32, String, UInt64 and the narrow integer types, round, clamp and other number helpers, and work on the bits of an Int or a Float.
---

Arithmetic never mixes `Int` and `Float`. Use these methods to convert: `n.to_f`, `x.to_i` and `x.to_i!`, and `to_s` for the text.

The bit functions work on the 64-bit two's complement form of an `Int` (`Int.bit_and`, `Int.shift_left` and the others) and on the IEEE 754 bits of a `Float` (`Float.to_bits` and the others). They are methods too: `flags.bit_and(4)`, `x.to_bits`. Masks read best in hex or binary: `0xFF`, `0b1010` (see [hex, binary and octal](/tour/numbers/#hex-binary-and-octal)).

The number helpers are methods, as in Ruby: `n.abs`, `n.pow(3)`, `a.gcd(b)`, `n.clamp(lo, hi)`, `x.floor`, `x.ceil`, `x.round`, and the functions of `Math`: `Math.sqrt(x)`, `Math.exp(x)`, `Math.log(x)`, `Math.log10(x)`, `Math.sin(x)` and `Math.cos(x)`. There is no `**` operator. For the least or greatest item of a list, see [min and max](/library/data-structures/list/#min-and-max).

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

## Int8, Int16, Int32, UInt8, UInt16 and UInt32

```signature
UInt8.to_i(uint8: UInt8) -> Int
Int.to_uint8(int: Int) -> Result[UInt8]
Int.to_uint8!(int: Int) -> UInt8
```

The integer types narrower than `Int`, each with its own range: `Int8` holds `-128` to `127`, `Int16` `-32768` to `32767`, `Int32` `-2147483648` to `2147483647`, `UInt8` `0` to `255`, `UInt16` `0` to `65535` and `UInt32` `0` to `4294967295`. `Int64` is another name of `Int`, and `Float64` of `Float`.

An integer literal takes the narrow type that its place expects: an annotation, a parameter, a struct field, a return type, a list or map item, or a `case` pattern on a value of that type. A minus before it is part of it, so `x: Int8 = -128` checks. A literal outside the type is `CHECK-INT-RANGE` at the literal. A value is never converted on its own: `to_i` gives the `Int`, `n.to_uint8` gives a Result that is an error when `n` is outside `0` to `255`, and `n.to_uint8!` stops the program there with `RUNTIME-INTEGER-OVERFLOW`. The same three methods exist for each narrow type: `to_int8`, `to_int16`, `to_int32`, `to_uint16` and `to_uint32`. The operators `+`, `-`, `*`, `/`, `%`, `<`, `<=`, `>`, `>=`, `==` and `!=` take two values of one narrow type, and an integer literal (or an arithmetic of literals, such as `(1 + 2) * 3`) on either side takes the type of the other side, so `a + 1` and `a == 255` work on a `UInt8`. Two different types, or a narrow type and an `Int`, are `CHECK-TYPE-MISMATCH`; convert one side. A result outside the type stops the program with `RUNTIME-INTEGER-OVERFLOW`, below zero as well: `UInt8` `3 - 5` does not wrap. An arithmetic of literals is checked step by step: `x: Int8 = -(64 + 64)` stops at `64 + 64`. `/` truncates toward zero and `%` takes the sign of the dividend, as for `Int`. An unsigned value has no unary minus (`CHECK-TYPE-MISMATCH`); write `0 - x`, which stops below zero.

```agentica
struct Pixel
  r: UInt8
  g: UInt8
end

def main() -> Void
  p = Pixel(r: 255, g: 0)
  low: Int8 = -128
  puts(p.inspect)
  puts(p.r.to_i + low.to_i)
  puts(300.to_uint8.ok?)
  puts(p.r == 255)
end
```

```output
Pixel(r: 255, g: 0)
127
false
true
```

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  n = 70000
  puts(n.to_uint16!)
end
```

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  r: UInt8 = 255
  puts(r + 1)
end
```

```signature
UInt8.bit_not(uint8: UInt8) -> UInt8
UInt8.shift_left(uint8: UInt8, count: Int) -> UInt8
UInt8.wrapping_add(uint8: UInt8, other: UInt8) -> UInt8
Int.wrap_uint8(int: Int) -> UInt8
Int.wrapping_add(int: Int, other: Int) -> Int
UInt8.to_uint16(uint8: UInt8) -> UInt16
UInt8.to_f(uint8: UInt8) -> Float
```

Each narrow type has the bit methods of `Int` (`bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left`, `shift_right`, `shift_right_unsigned`), read at the width of the type: the result is the low bits, read back in the type. `bit_not` of an unsigned value flips the bits within its width (`UInt8` `0` gives `255`), and of a signed value it is `-1 - x`. `shift_left` drops the bits that leave the width, and a count of the width or more gives `0`. `shift_right` copies the sign bit of a signed type and fills an unsigned one with zeros; `shift_right_unsigned` always fills with zeros, so on `Int8` `-100` it shifts the 8 bits `156`. A negative count stops the program with `RUNTIME-INVALID-COUNT`.

The operators stop on overflow; for arithmetic that wraps, `wrapping_add`, `wrapping_sub` and `wrapping_mul` keep the low bits of the result in the type, on every narrow type and on `Int` (the low 64 bits). `n.wrap_uint8` is the `UInt8` of the low 8 bits of an `Int`, and never fails: the same method exists for the other five types (`wrap_int8`, `wrap_int16`, `wrap_int32`, `wrap_uint16` and `wrap_uint32`).

A conversion that cannot fail is a plain method with no Result: `x.to_uint16` on a `UInt8`, and the same for every widening that holds all the values of the source (a signed type to a wider signed type, an unsigned type to a wider unsigned or signed type). `to_f` gives the `Float` of any narrow value. Any other conversion goes through `Int`: `x.to_i.to_uint8!`.

```agentica
def main() -> Void
  a: UInt8 = 200
  b: Int8 = -100
  puts(a.bit_not)
  puts(a.shift_left(1))
  puts(b.shift_right_unsigned(1))
  puts(a.wrapping_add(100))
  puts(300.wrap_uint8)
  puts(a.to_uint16 + 1000)
end
```

```output
55
144
78
44
44
1200
```

A narrow type is a `Map` key and a `Set` element, like `Int`. In [JSON](/library/text-and-data/json/), `JSON.encode` writes it as a number, `JSON.decode` reads only an integer in its range (`r: expected UInt8 from 0 to 255` otherwise), and `JSON.schema` gives its range as `minimum` and `maximum`.

## UInt64

```signature
Int.to_uint64(int: Int) -> Result[UInt64]
Int.to_uint64!(int: Int) -> UInt64
Int.wrap_uint64(int: Int) -> UInt64
UInt64.to_i(uint64: UInt64) -> Result[Int]
UInt64.to_i!(uint64: UInt64) -> Int
UInt64.to_f(uint64: UInt64) -> Float
UInt32.to_uint64(uint32: UInt32) -> UInt64
```

`UInt64` holds `0` to `18446744073709551615`. A literal of a `UInt64` place may be above the greatest `Int` (`x: UInt64 = 18446744073709551615`), and a larger one is `CHECK-INT-RANGE`. Unlike the narrow types it is not an `Int` at run time: `+`, `-`, `*`, `/`, `%` and the comparisons work on the unsigned value, so `2^63` is above `2^63 - 1`. A sum or product above the range and a difference below `0` stop the program with `RUNTIME-INTEGER-OVERFLOW`, a zero divisor with `RUNTIME-DIVISION-BY-ZERO`, and there is no unary minus. An `Int` never becomes a `UInt64` on its own: `n.to_uint64` is an error Result below `0` (`n.to_uint64!` halts there), and `n.wrap_uint64` takes the 64 bits of `n`, so `-1` gives `18446744073709551615`. `x.to_i` is an error Result above the greatest `Int` (`x.to_i!` halts), and `x.to_f` is the nearest `Float`. `UInt8`, `UInt16` and `UInt32` widen with `to_uint64`. The bit methods and `wrapping_add`, `wrapping_sub` and `wrapping_mul` work on all 64 bits, and a shift count of 64 or more gives `0`. A `UInt64` is a `Map` key and a `Set` element, `List.sort` orders it as an unsigned number, and in [JSON](/library/text-and-data/json/) it is a number up to `18446744073709551615`.

```agentica
def main() -> Void
  top: UInt64 = 18446744073709551615
  puts(top / 10)
  puts(top > 9223372036854775807.to_uint64!)
  puts(top.to_i.ok?)
  puts((-1).wrap_uint64 == top)
  puts(top.wrapping_add(2))
  puts(top.shift_right(60))
end
```

```output
1844674407370955161
true
false
true
1
15
```

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  top: UInt64 = 18446744073709551615
  puts(top + 1)
end
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

Two outputs differ from Ruby: `%x` of a negative number is `-ff` where Ruby writes `..f01`, and `%s` of `nil` is `nil` where Ruby writes an empty string. `%f` rounds an exact tie, such as `format("%.1f", -1.25)`, to even (`-1.2`), except on Windows 10 before version 2004, whose C library rounds it away from zero (`-1.3`).

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

## Math.exp, Math.log, Math.log10, Math.sin and Math.cos

```signature
Math.exp(float: Float) -> Float
Math.log(float: Float) -> Float
Math.log10(float: Float) -> Float
Math.sin(float: Float) -> Float
Math.cos(float: Float) -> Float
```

`exp` is e raised to `float`, `log` is the natural logarithm, `log10` is the base-10 logarithm, and `sin` and `cos` take an angle in radians. They follow Ruby. A negative `float` in `log` or `log10` stops the program with `RUNTIME-INVALID-NUMBER` at the argument, as Ruby raises `Math::DomainError`; `0.0` and `-0.0` give -Infinity. `exp` of a large number gives infinity, `sin` and `cos` of an infinity give NaN, and a NaN stays NaN. For e itself, write `Math.exp(1.0)` or `2.718281828459045`.

```agentica
def main() -> Void
  puts(Math.exp(1.0))
  puts(Math.log(1.0))
  puts(Math.log10(1000.0))
  puts(Math.sin(0.0))
  puts(Math.cos(0.0))
end
```

```output
2.718281828459045
0.0
3.0
0.0
1.0
```

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Math.log(0.0 - 1.0))
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

## Float32

```signature
Float32.to_f(float32: Float32) -> Float
Float.to_float32(float: Float) -> Float32
Int.to_float32(int: Int) -> Float32
Float32.to_bits(float32: Float32) -> UInt32
Float32.from_bits(bits: UInt32) -> Float32
```

`Float32` is an IEEE 754 binary32 number. A float literal takes it where its place expects it, as an integer literal takes a narrow type: an annotation, a parameter, a struct field, a return type, a list or map item, a `case` pattern, or the other side of an operator. The literal is rounded once to the nearest `Float32`, ties to even. An integer literal never becomes a `Float32`, and a literal that would round to an infinity is `CHECK-FLOAT-RANGE` at the literal, from `2^128 - 2^103` (about `3.4028235677973366e38`) up; a `Float` literal from `2^1024 - 2^970` (about `1.7976931348623158e308`) up is `CHECK-FLOAT-RANGE` too.

The operators `+`, `-`, `*`, `/`, `<`, `<=`, `>`, `>=`, `==` and `!=` take two `Float32` values; a `Float32` and a `Float` are `CHECK-TYPE-MISMATCH`, and there is no `%`. Each result is the `Float32` nearest the exact one. A result past the largest `Float32` is an infinity, a zero divisor is `RUNTIME-DIVISION-BY-ZERO`, and NaN and `-0.0` behave as for `Float`. `to_s` gives the fewest digits that read back as the same value, so the `Float32` nearest `0.1` prints `0.1`.

`x.to_f` widens a `Float32` exactly. `f.to_float32` rounds a `Float` to the nearest `Float32` (an infinity past the largest), and `n.to_float32` rounds an `Int` or a narrow integer once, from its own value. `to_bits` gives the 32 bits as a `UInt32`, every NaN as `2143289344`, and `Float32.from_bits` reads them back. `sum`, `min`, `max`, `sort` and `sort_by` refuse a `List[Float32]` (`CHECK-TYPE-MISMATCH`): widen it first, `xs.map { |x| x.to_f }.sum`. In [JSON](/library/text-and-data/json/), a `Float32` is written as its shortest text and read as the `Float32` nearest the number's text; a number past the largest `Float32` is an error.

```agentica
def main() -> Void
  x: Float32 = 0.1
  puts(x)
  puts(x.to_f)
  puts(x * 3.0)
  puts(x.to_bits)
  puts(Float32.from_bits(1065353216))
  puts(16777217.to_float32)
  big: Float32 = 3.0e38
  puts(big * 2.0)
end
```

```output
0.1
0.10000000149011612
0.3
1036831949
1.0
16777216.0
+inf.0
```

```agentica {expect="CHECK-FLOAT-RANGE"}
def main() -> Void
  x: Float32 = 1e39
  puts(x)
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
