---
title: Int y Float
weight: 2
description: Convierte entre Int, Float, String y los tipos enteros de menos bits, redondea, acota y usa otras funciones auxiliares de números, y trabaja con los bits de un Int o de un Float.
source_hash: "64e0c0cfbca8"
---

La aritmética nunca mezcla `Int` y `Float`. Usa estos métodos para convertir: `n.to_f`, `x.to_i` y `x.to_i!`, y `to_s` para el texto.

Las funciones de bits trabajan sobre la forma de complemento a dos de 64 bits de un `Int` (`Int.bit_and`, `Int.shift_left` y las demás) y sobre los bits IEEE 754 de un `Float` (`Float.to_bits` y las demás). También son métodos: `flags.bit_and(4)`, `x.to_bits`. Las máscaras se leen mejor en hexadecimal o binario: `0xFF`, `0b1010` (consulta [hexadecimal, binario y octal](/tour/numbers/#hex-binary-and-octal)).

Las funciones auxiliares de números son métodos, como en Ruby: `n.abs`, `n.pow(3)`, `a.gcd(b)`, `n.clamp(lo, hi)`, `x.floor`, `x.ceil`, `x.round`, y las funciones de `Math`: `Math.sqrt(x)`, `Math.exp(x)`, `Math.log(x)`, `Math.log10(x)`, `Math.sin(x)` y `Math.cos(x)`. No hay operador `**`. Para el elemento menor o mayor de una lista, consulta [mínimo y máximo](/library/data-structures/list/#min-and-max).

Para leer números de un texto, consulta [to_i y to_f](/library/text-and-data/string/#to_i-and-to_f). Para los métodos de bucle `n.times`, `a.upto(b)` y `a.downto(b)`, consulta [Rango](/library/data-structures/range/#times-upto-and-downto).

## to_s {#to_s}

```signature
Int.to_s(int: Int) -> String
Float.to_s(float: Float) -> String
```

El texto de un número, como lo escriben `puts` y la interpolación.

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

## to_f {#to_f}

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

## to_i {#to_i}

```signature
Float.to_i(float: Float) -> Result[Int]
```

Corta los decimales, hacia cero. Un valor que no cabe en un `Int`, o que no es un número (NaN o un infinito), da un Result de error.

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

## to_i! {#to_i-1}

```signature
Float.to_i!(float: Float) -> Int
```

Igual que `to_i`, pero da el `Int` mismo y detiene el programa con un valor malo, con `RUNTIME-INVALID-NUMBER` o `RUNTIME-INTEGER-OVERFLOW`.

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

## Int8, Int16, Int32, UInt8, UInt16 y UInt32 {#int8-int16-int32-uint8-uint16-and-uint32}

```signature
UInt8.to_int(uint8: UInt8) -> Int
Int.to_uint8(int: Int) -> Result[UInt8]
Int.to_uint8!(int: Int) -> UInt8
```

Los tipos enteros de menos bits que `Int`, cada uno con su rango: `Int8` va de `-128` a `127`, `Int16` de `-32768` a `32767`, `Int32` de `-2147483648` a `2147483647`, `UInt8` de `0` a `255`, `UInt16` de `0` a `65535` y `UInt32` de `0` a `4294967295`. `Int64` es otro nombre de `Int`, y `Float64` de `Float`.

Un literal entero toma el tipo de menos bits que espera su lugar: una anotación, un parámetro, un campo de un struct, un tipo de retorno, un elemento de una lista o de un mapa, o un patrón de `case` sobre un valor de ese tipo. Un signo menos delante es parte del literal, así que `x: Int8 = -128` pasa la comprobación. Un literal fuera del tipo es `CHECK-INT-RANGE` en el literal. Un valor nunca se convierte solo: `to_int` da el `Int`, `n.to_uint8` da un Result que es un error cuando `n` está fuera de `0` a `255`, y `n.to_uint8!` detiene el programa ahí con `RUNTIME-INTEGER-OVERFLOW`. Los mismos tres métodos existen para cada tipo de menos bits: `to_int8`, `to_int16`, `to_int32`, `to_uint16` y `to_uint32`.

```agentica
struct Pixel
  r: UInt8
  g: UInt8
end

def main() -> Void
  p = Pixel(r: 255, g: 0)
  low: Int8 = -128
  puts(p.inspect)
  puts(p.r.to_int + low.to_int)
  puts(300.to_uint8.ok?)
  puts(200.to_uint8! == p.r)
end
```

```output
Pixel(r: 255, g: 0)
127
false
false
```

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  n = 70000
  puts(n.to_uint16!)
end
```

## abs, pow y gcd {#abs-pow-and-gcd}

```signature
Int.abs(int: Int) -> Int
Float.abs(float: Float) -> Float
Int.pow(int: Int, exponent: Int) -> Int
Int.gcd(int: Int, other: Int) -> Int
```

- `abs` del `Int` más pequeño, `-9223372036854775808`, no cabe y es `RUNTIME-INTEGER-OVERFLOW`, como lo es `-n`. `Float.abs` quita el signo, así que `-0.0` da `0.0`, y un NaN sigue siendo NaN.
- `n.pow(e)` es `n` elevado a `e`; `n.pow(0)` es `1`, y `0.pow(0)` también. Un resultado de más de 64 bits es `RUNTIME-INTEGER-OVERFLOW` en la llamada. Un exponente negativo es `RUNTIME-INVALID-COUNT` en el exponente: Ruby da ahí una fracción, que un `Int` no puede contener.
- `gcd` nunca es negativo, y `0.gcd(0)` es `0`. El único resultado que no cabe es `2^63`, del `Int` más pequeño con `0` o consigo mismo: `RUNTIME-INTEGER-OVERFLOW`.

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

## clamp {#clamp}

```signature
Int.clamp(int: Int, min: Int, max: Int) -> Int
Float.clamp(float: Float, min: Float, max: Float) -> Float
```

Da `min` cuando el número está por debajo, `max` cuando está por encima, y el número mismo en otro caso. `min > max` detiene el programa con `RUNTIME-INVALID-RANGE`, como en Ruby (ahí, un `ArgumentError`). En un `Float`, un límite NaN también es `RUNTIME-INVALID-RANGE`, y un `float` NaN devuelve NaN.

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

## floor, ceil y round {#floor-ceil-and-round}

```signature
Float.floor(float: Float) -> Int
Float.ceil(float: Float) -> Int
Float.round(float: Float) -> Int
```

Dan un `Int`, como `Float#floor` de Ruby da un `Integer`. `floor` va hacia abajo, `ceil` va hacia arriba, y `round` va al entero más cercano, y los empates se alejan de cero: `2.5.round` es `3` y `(-2.5).round` es `-3`. Como `x.to_i!`, NaN o un infinito es `RUNTIME-INVALID-NUMBER`, y un resultado fuera de `Int` es `RUNTIME-INTEGER-OVERFLOW`. `round` no recibe número de dígitos; [`format("%.2f", x)`](#format) escribe un Float con dos dígitos después del punto.

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

## format {#format}

```signature
format(format: String, args...) -> String
```

El texto de una cadena de formato con un argumento por cada conversión, como `format` de Ruby. Una conversión es `%[flags][width][.precision]type`:

- `d`: un `Int` en decimal.
- `x`: un `Int` en hexadecimal en minúsculas; un número negativo es `-` y el hexadecimal de su magnitud (`-ff`).
- `f`: un `Float` en punto fijo, con 6 dígitos después del punto salvo que `.precision` (de 0 a 50) indique otra cosa. Redondea el valor binario exacto, como lo hacen C y Ruby: `format("%.2f", 2.675)` es `2.67`, ya que `2.675` está un poco por debajo. NaN, `Inf` y `-Inf` se escriben como en Ruby.
- `s`: cualquier valor con `to_s`, como lo escribe `puts`.
- `%%` es un `%`.

El flag `0` rellena un número con ceros después de su signo, y `-` rellena a la derecha con espacios; sin flag, el relleno son espacios a la izquierda. `width` va de 1 a 1000 y cuenta caracteres, como lo hace `String.length`. Un `Int` para `%f` no se convierte: escribe `n.to_f`.

Dos salidas difieren de Ruby: `%x` de un número negativo es `-ff` donde Ruby escribe `..f01`, y `%s` de `nil` es `nil` donde Ruby escribe una cadena vacía. `%f` redondea un empate exacto, como `format("%.1f", -1.25)`, al número par (`-1.2`), salvo en Windows 10 anterior a la versión 2004, cuya biblioteca de C lo redondea alejándose de cero (`-1.3`).

El formato debe ser un literal de cadena `"..."` en una sola línea, que lee el comprobador: una conversión que no conoce (`%X`, `%e`, los flags `+`, espacio y `#`, una precisión en `d`, `x` o `s`) es `CHECK-FORMAT-SPEC` en esa conversión, otro primer argumento es `CHECK-FORMAT-LITERAL`, un número de argumentos incorrecto es `CHECK-ARITY`, y un argumento de tipo incorrecto es `CHECK-TYPE-MISMATCH`. Un formato cuyas conversiones son solo un `%s` o `%d` simple también es `CHECK-FORMAT-SPEC`: escribe `"#{x}"`.

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

## Math.sqrt {#mathsqrt}

```signature
Math.sqrt(float: Float) -> Float
```

La raíz cuadrada. Un `float` negativo detiene el programa con `RUNTIME-INVALID-NUMBER` en el argumento, como Ruby lanza `Math::DomainError`. `-0.0` da `-0.0`, el infinito da infinito, y un NaN sigue siendo NaN. Para un `Int`, convierte primero: `Math.sqrt(n.to_f)`.

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

## Math.exp, Math.log, Math.log10, Math.sin y Math.cos {#mathexp-mathlog-mathlog10-mathsin-and-mathcos}

```signature
Math.exp(float: Float) -> Float
Math.log(float: Float) -> Float
Math.log10(float: Float) -> Float
Math.sin(float: Float) -> Float
Math.cos(float: Float) -> Float
```

`exp` es e elevado a `float`, `log` es el logaritmo natural, `log10` es el logaritmo en base 10, y `sin` y `cos` toman un ángulo en radianes. Siguen a Ruby. Un `float` negativo en `log` o `log10` detiene el programa con `RUNTIME-INVALID-NUMBER` en el argumento, como Ruby lanza `Math::DomainError`; `0.0` y `-0.0` dan -Infinity. `exp` de un número grande da infinito, `sin` y `cos` de un infinito dan NaN, y un NaN sigue siendo NaN. Para el propio e, escribe `Math.exp(1.0)` o `2.718281828459045`.

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

## Int.bit_and, Int.bit_or y Int.bit_xor {#intbit_and-intbit_or-and-intbit_xor}

```signature
Int.bit_and(int: Int, other: Int) -> Int
Int.bit_or(int: Int, other: Int) -> Int
Int.bit_xor(int: Int, other: Int) -> Int
Int.bit_not(int: Int) -> Int
```

Combinan los bits de dos números, bit a bit. Nunca fallan. `Int.bit_not(a)` invierte cada bit y es lo mismo que `-1 - a`. Un número negativo tiene su bit de signo activado, así que `Int.bit_and(-1, 255)` es `255`.

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

## Int.shift_left, Int.shift_right y Int.shift_right_unsigned {#intshift_left-intshift_right-and-intshift_right_unsigned}

```signature
Int.shift_left(int: Int, count: Int) -> Int
Int.shift_right(int: Int, count: Int) -> Int
Int.shift_right_unsigned(int: Int, count: Int) -> Int
```

- `shift_left(int, count)` es el resultado de los 64 bits bajos de `int * 2^count`: los bits que salen por arriba se descartan y el bit 63 pasa a ser el signo, así que `1.shift_left(63)` es `-9223372036854775808`. Usa `x * 2` para comprobar el desbordamiento.
- `shift_right` es aritmético (entra el bit de signo), así que redondea hacia menos infinito: `(-7).shift_right(1)` es `-4`.
- `shift_right_unsigned` es lógico (entran ceros): lee `int` como un número sin signo de 64 bits. `(-1).shift_right_unsigned(64 - n)` enmascara los `n` bits bajos.
- Una cantidad de 64 o más saca todos los bits: el resultado es `0`, o `-1` para `shift_right` de un `int` negativo. Una cantidad negativa es `RUNTIME-INVALID-COUNT`.

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

## Float.to_bits y Float.from_bits {#floatto_bits-and-floatfrom_bits}

```signature
Float.to_bits(float: Float) -> Int
Float.from_bits(bits: Int) -> Float
```

`to_bits` da los bits IEEE 754 binary64 de `float` como un `Int` en complemento a dos (`1.0` es `4607182418800017408`, `-0.0` es `-9223372036854775808`). Todo NaN da el NaN silencioso `9221120237041090560`. `x.to_bits < 0` comprueba el bit de signo de cada valor salvo NaN (para NaN, comprueba con `x != x`), y `to_bits` distingue `-0.0` de `0.0`.

`from_bits` lee los 64 bits de cualquier `Int` como binary64; los subnormales, los infinitos y `-0.0` vuelven exactos, y cualquier patrón NaN da NaN. Así que `Float.to_bits(Float.from_bits(n)) == n` para todo `n`, salvo los patrones NaN distintos del NaN silencioso.

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

## Float.to_bits32 y Float.from_bits32 {#floatto_bits32-and-floatfrom_bits32}

```signature
Float.to_bits32(float: Float) -> Int
Float.from_bits32(bits: Int) -> Float
```

`to_bits32` redondea `float` a binary32, al más cercano con empates hacia el número par, y da sus 32 bits como un `Int` de 0 a 4294967295. Una magnitud de `2^128 - 2^103` o más se vuelve infinito con el mismo signo. Una muy pequeña se redondea a un subnormal o a cero y conserva su signo. Todo NaN da `2143289344`.

`from_bits32` lee 32 bits como binary32 y los amplía a un `Float`, lo que siempre es exacto. Un `Int` fuera de `0 .. 4294967295` es `RUNTIME-INVALID-NUMBER` en el argumento. Así que `Float.to_bits32(Float.from_bits32(n)) == n` para todo `n`, salvo los patrones NaN distintos de `2143289344`.

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

## Int a texto {#int-to-text}

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
