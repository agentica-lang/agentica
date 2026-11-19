---
title: Números
weight: 4
description: Int y Float, aritmética, comparación y conversión.
source_hash: "fc4b8b30c9e2"
---

## Int y Float {#int-and-float}

`Int` guarda números enteros de 64 bits. `Float` guarda números decimales.

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

## Exponentes {#exponents}

Un Float puede terminar en un exponente, `e` o `E` con un signo opcional: `1.5e-3` es `0.0015` y `2.0E+10` es `20000000000.0`. Debe haber un dígito antes de la `e`, así que `1.e5` no es un número, y `1e5` es un Float.

```agentica
def main() -> Void
  puts(1.5e-3)
  puts(2.0E+10)
  puts(1e5)
end
```

```output
0.0015
20000000000.0
100000.0
```

## Números largos {#long-numbers}

Un `_` entre dígitos es solo visual: `1_000` es el mismo `Int` que `1000`.

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

`1_`, `1__0`, `1_.5` y `1._5` son `LEX-INVALID-NUMBER`. `s.to_i` y `s.to_f` rechazan un `_` en el texto.

## Hexadecimal, binario y octal {#hex-binary-and-octal}

`0x`, `0b` y `0o` escriben un `Int` en base 16, 2 u 8, como en Ruby. El prefijo y las letras hexadecimales admiten mayúsculas o minúsculas, y `_` separa dígitos también aquí.

```agentica
def main() -> Void
  puts(0xFF)
  puts(0b1010_1010)
  puts(0o755)
  puts(0x7FFF_FFFF_FFFF_FFFF)
end
```

```output
255
170
493
9223372036854775807
```

El rango es el de `Int`: `0x8000_0000_0000_0000` es `CHECK-INT-RANGE`. Un prefijo sin dígito (`0x`), un dígito fuera de la base (`0b102`, `0o8`) o un `_` mal colocado (`0xFF_`) es `LEX-INVALID-NUMBER`. Un cero inicial, por sí solo, sigue siendo decimal: `0755` es `755`.

## División {#division}

`/` entre dos valores `Int` descarta los decimales, hacia cero. `%` es el resto y funciona solo con `Int`.

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

Dividir entre cero detiene el programa con un error, también con `Float`:

```agentica {expect="RUNTIME-DIVISION-BY-ZERO"}
def main() -> Void
  zero = 0
  puts(10 / zero)
end
```

## Mezclar Int y Float {#mixing-int-and-float}

Los dos lados de un operador deben tener el mismo tipo. Convierte con `to_f` o `to_i!`.

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

## Comparación {#comparison}

`<`, `<=`, `>` y `>=` comparan dos números del mismo tipo. `==` y `!=` funcionan con números, `Bool`, `String` y `nil`.

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

Las comparaciones no se encadenan. Escribe `a < b and b < c`.

## Números negativos {#negative-numbers}

El signo menos es un operador. Usa paréntesis para llamar a un método en un literal negativo:

```agentica
def main() -> Void
  puts((-5).to_s + " degrees")
end
```

```output
-5 degrees
```

## De texto a números {#text-to-numbers}

`to_i` y `to_f` leen un número de una cadena. Devuelven un [Result](/tour/results-and-try/), porque el texto puede no ser un número. `to_i!` y `to_f!` devuelven el número y detienen el programa si el texto no es un número válido.

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
error("cannot convert \"4x\" to Int", kind: "number.parse")
43
2.5
```

## Desbordamiento {#overflow}

El desbordamiento de `Int` es un error. Nunca pasa al otro extremo.

```agentica {expect="RUNTIME-INTEGER-OVERFLOW"}
def main() -> Void
  big = 9223372036854775807
  puts(big + 1)
end
```

Consulta [Int y Float](/library/text-and-data/numbers/) para ver todas las funciones de conversión.
