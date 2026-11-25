---
title: Int y Float
weight: 2
description: Convierte entre Int, Float, Float32, String, UInt64 y los tipos enteros de menos bits, redondea, acota y usa otras funciones auxiliares de números, y trabaja con los bits de un Int o de un Float.
source_hash: "85c1ef01237b"
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
UInt8.to_i(uint8: UInt8) -> Int
Int.to_uint8(int: Int) -> Result[UInt8]
Int.to_uint8!(int: Int) -> UInt8
```

Los tipos enteros de menos bits que `Int`, cada uno con su rango: `Int8` va de `-128` a `127`, `Int16` de `-32768` a `32767`, `Int32` de `-2147483648` a `2147483647`, `UInt8` de `0` a `255`, `UInt16` de `0` a `65535` y `UInt32` de `0` a `4294967295`. `Int64` es otro nombre de `Int`, y `Float64` de `Float`.

Un literal entero toma el tipo de menos bits que espera su lugar: una anotación, un parámetro, un campo de un struct, un tipo de retorno, un elemento de una lista o de un mapa, un patrón de `case` sobre un valor de ese tipo, o el tipo que otro argumento de la llamada da a la variable de tipo de su parámetro (`List.append(bytes, 1)`). Un signo menos delante es parte del literal, así que `x: Int8 = -128` pasa la comprobación. Un literal fuera del tipo es `CHECK-INT-RANGE` en el literal. Un valor nunca se convierte solo: `to_i` da el `Int`, `n.to_uint8` da un Result que es un error cuando `n` está fuera de `0` a `255`, y `n.to_uint8!` detiene el programa ahí con `RUNTIME-INTEGER-OVERFLOW`. Los mismos tres métodos existen para cada tipo de menos bits: `to_int8`, `to_int16`, `to_int32`, `to_uint16` y `to_uint32`. Los operadores `+`, `-`, `*`, `/`, `%`, `<`, `<=`, `>`, `>=`, `==` y `!=` toman dos valores de un mismo tipo de menos bits, y un literal entero (o una aritmética de literales, como `(1 + 2) * 3`) en cualquier lado toma el tipo del otro lado, así que `a + 1` y `a == 255` funcionan con un `UInt8`. Dos tipos distintos, o un tipo de menos bits y un `Int`, son `CHECK-TYPE-MISMATCH`; convierte un lado. Un resultado fuera del tipo detiene el programa con `RUNTIME-INTEGER-OVERFLOW`, también por debajo de cero: `3 - 5` con `UInt8` no da la vuelta. Una aritmética de literales se comprueba paso a paso: `x: Int8 = -(64 + 64)` se detiene en `64 + 64`. `/` trunca hacia cero y `%` toma el signo del dividendo, como con `Int`. Un valor sin signo no tiene el menos unario (`CHECK-TYPE-MISMATCH`); escribe `0 - x`, que se detiene por debajo de cero.

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

Cada tipo de menos bits tiene los métodos de bits de `Int` (`bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left`, `shift_right`, `shift_right_unsigned`), leídos con el ancho del tipo: el resultado son los bits bajos, leídos de nuevo en el tipo. `bit_not` de un valor sin signo invierte los bits dentro de su ancho (`UInt8` `0` da `255`), y de un valor con signo es `-1 - x`. `shift_left` descarta los bits que salen del ancho, y una cuenta igual o mayor que el ancho da `0`. `shift_right` copia el bit de signo de un tipo con signo y rellena con ceros uno sin signo; `shift_right_unsigned` siempre rellena con ceros, así que en `Int8` `-100` desplaza los 8 bits `156`. Una cuenta negativa detiene el programa con `RUNTIME-INVALID-COUNT`.

Los operadores se detienen al desbordar; para una aritmética que da la vuelta, `wrapping_add`, `wrapping_sub` y `wrapping_mul` dejan en el tipo los bits bajos del resultado, en cada tipo de menos bits y en `Int` (los 64 bits bajos). `n.wrap_uint8` es el `UInt8` de los 8 bits bajos de un `Int`, y nunca falla: los otros cinco tipos tienen el mismo método (`wrap_int8`, `wrap_int16`, `wrap_int32`, `wrap_uint16` y `wrap_uint32`).

Una conversión que no puede fallar es un método simple, sin Result: `x.to_uint16` en un `UInt8`, y lo mismo para cada ampliación que contiene todos los valores del origen (un tipo con signo a otro con signo más ancho, un tipo sin signo a otro sin signo o con signo más ancho). `to_f` da el `Float` de cualquier valor de menos bits. Cualquier otra conversión pasa por `Int`: `x.to_i.to_uint8!`.

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

Un tipo de menos bits es una clave de `Map` y un elemento de `Set`, como `Int`. En [JSON](/library/text-and-data/json/), `JSON.encode` lo escribe como un número, `JSON.decode` solo lee un entero dentro de su rango (si no, `r: expected UInt8 from 0 to 255`), y `JSON.schema` da su rango como `minimum` y `maximum`.

## UInt64 {#uint64}

```signature
Int.to_uint64(int: Int) -> Result[UInt64]
Int.to_uint64!(int: Int) -> UInt64
Int.wrap_uint64(int: Int) -> UInt64
UInt64.to_i(uint64: UInt64) -> Result[Int]
UInt64.to_i!(uint64: UInt64) -> Int
UInt64.to_f(uint64: UInt64) -> Float
UInt32.to_uint64(uint32: UInt32) -> UInt64
```

`UInt64` guarda de `0` a `18446744073709551615`. Un literal en un lugar de `UInt64` puede ser mayor que el `Int` más grande (`x: UInt64 = 18446744073709551615`), y uno mayor es `CHECK-INT-RANGE`. A diferencia de los tipos de menos bits, en ejecución no es un `Int`: `+`, `-`, `*`, `/`, `%` y las comparaciones trabajan con el valor sin signo, así que `2^63` es mayor que `2^63 - 1`. Una suma o un producto sobre el rango y una resta bajo `0` detienen el programa con `RUNTIME-INTEGER-OVERFLOW`, un divisor cero con `RUNTIME-DIVISION-BY-ZERO`, y no hay menos unario. Un `Int` nunca pasa a `UInt64` solo: `n.to_uint64` es un Result de error bajo `0` (`n.to_uint64!` se detiene ahí), y `n.wrap_uint64` toma los 64 bits de `n`, así que `-1` da `18446744073709551615`. `x.to_i` es un Result de error sobre el `Int` más grande (`x.to_i!` se detiene), y `x.to_f` es el `Float` más cercano. `UInt8`, `UInt16` y `UInt32` se ensanchan con `to_uint64`. Los métodos de bits y `wrapping_add`, `wrapping_sub` y `wrapping_mul` trabajan con los 64 bits, y un conteo de desplazamiento de 64 o más da `0`. Un `UInt64` es una clave de `Map` y un elemento de `Set`, `List.sort` lo ordena como número sin signo, y en [JSON](/library/text-and-data/json/) es un número hasta `18446744073709551615`.

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
Float.to_bits(float: Float) -> UInt64
Float.from_bits(bits: UInt64) -> Float
```

`to_bits` da los bits IEEE 754 binary64 de `float` como un `UInt64` (`1.0` es `4607182418800017408`, `-0.0` es `9223372036854775808`). Todo NaN da el NaN silencioso `9221120237041090560`. `x.to_bits >= 9223372036854775808` comprueba el bit de signo de cada valor salvo NaN (para NaN, comprueba con `x != x`), y `to_bits` distingue `-0.0` de `0.0`.

`from_bits` lee los 64 bits de cualquier `UInt64` como binary64; los subnormales, los infinitos y `-0.0` vuelven exactos, y cualquier patrón NaN da NaN. Así que `Float.to_bits(Float.from_bits(n)) == n` para todo `n`, salvo los patrones NaN distintos del NaN silencioso.

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
13835058055282163712
true
9223372036854775808
1.0
true
true
```

## Float32 {#float32}

```signature
Float32.to_f(float32: Float32) -> Float
Float.to_float32(float: Float) -> Float32
Int.to_float32(int: Int) -> Float32
Float32.to_bits(float32: Float32) -> UInt32
Float32.from_bits(bits: UInt32) -> Float32
```

`Float32` es un número binary32 de IEEE 754. Un literal flotante lo toma donde su lugar lo espera, en los mismos lugares en que un literal entero toma un tipo de menos bits. El literal se redondea una sola vez al `Float32` más cercano, con empates hacia el número par. Un literal entero nunca se vuelve un `Float32`, y un literal que se redondearía a un infinito es `CHECK-FLOAT-RANGE` en el literal, desde `2^128 - 2^103` (unos `3.4028235677973366e38`) hacia arriba; un literal `Float` desde `2^1024 - 2^970` (unos `1.7976931348623158e308`) hacia arriba también es `CHECK-FLOAT-RANGE`.

Los operadores `+`, `-`, `*`, `/`, `<`, `<=`, `>`, `>=`, `==` y `!=` toman dos valores `Float32`; un `Float32` y un `Float` son `CHECK-TYPE-MISMATCH`, y no hay `%`. Cada resultado es el `Float32` más cercano al exacto. Un resultado más allá del mayor `Float32` es un infinito, un divisor cero es `RUNTIME-DIVISION-BY-ZERO`, y NaN y `-0.0` se comportan como con `Float`. `to_s` da la menor cantidad de dígitos que se leen de vuelta como el mismo valor, así que el `Float32` más cercano a `0.1` se imprime `0.1`.

`x.to_f` amplía un `Float32` de forma exacta. `f.to_float32` redondea un `Float` al `Float32` más cercano (un infinito más allá del mayor), y `n.to_float32` redondea un `Int` o un tipo entero de menos bits una sola vez, desde su propio valor. `to_bits` da los 32 bits como un `UInt32`, todo NaN como `2143289344`, y `Float32.from_bits` los lee de vuelta. `sum`, `min`, `max`, `sort` y `sort_by` rechazan un `List[Float32]` (`CHECK-TYPE-MISMATCH`): amplíalo primero, `xs.map { |x| x.to_f }.sum`. En [JSON](/library/text-and-data/json/), un `Float32` se escribe como su texto más corto y se lee como el `Float32` más cercano al texto del número; un número más allá del mayor `Float32` es un error.

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
