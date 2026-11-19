---
title: String
weight: 1
description: Funciones para texto. Cada una es también un método de los valores String.
source_hash: "e5e55cae4ba3"
---

Las cadenas son texto Unicode. Las longitudes y los índices cuentan caracteres, no bytes; `bytesize` cuenta los bytes UTF-8.

## Alias {#aliases}

Como en Ruby, `s.size` es lo mismo que `s.length`.

## length y empty? {#length-and-empty}

```signature
String.length(string: String) -> Int
String.empty?(string: String) -> Bool
```

`length` cuenta los caracteres Unicode. `empty?` es verdadero cuando no hay ninguno.

```agentica
def main() -> Void
  puts("hello".length)
  puts(String.length("café"))
  puts("".empty?)
  puts("hello".empty?)
end
```

```output
5
4
true
false
```

## upcase y downcase {#upcase-and-downcase}

```signature
String.upcase(string: String) -> String
String.downcase(string: String) -> String
```

```agentica
def main() -> Void
  puts("Hello".upcase)
  puts("Hello".downcase)
end
```

```output
HELLO
hello
```

## strip {#strip}

```signature
String.strip(string: String) -> String
```

Quita los espacios, tabuladores y saltos de línea de ambos extremos.

```agentica
def main() -> Void
  puts("[" + "  hi \n".strip + "]")
end
```

```output
[hi]
```

## split {#split}

```signature
String.split(string: String, separator: String) -> List[String]
```

Corta el texto en cada separador. Se conserva cada parte, incluso una vacía al principio o al final, o entre dos separadores, así que `join` con el mismo separador devuelve el texto. Un texto vacío da `[""]`. Un separador vacío da los caracteres.

```agentica
def main() -> Void
  puts("a,b,c".split(","))
  puts("a,,b,".split(","))
  puts("line\n".split("\n"))
  puts("".split(","))
  puts("a,,b,".split(",").join(","))
  puts("abc".split(""))
end
```

```output
["a", "b", "c"]
["a", "", "b", ""]
["line", ""]
[""]
a,,b,
["a", "b", "c"]
```

## join {#join}

```signature
List.join(list: List[String], separator: String) -> String
```

Un método de un `List[String]`: pone el separador entre las partes.

```agentica
def main() -> Void
  puts(["a", "b", "c"].join("-"))
  puts(["x", "y"].join(", "))
end
```

```output
a-b-c
x, y
```

## Repetir con * {#repeating-with-}

`s * n` da `n` copias de `s`, como `String#*` de Ruby. La cantidad es un `Int` y va en segundo lugar: `3 * "ab"` y `"ab" * "c"` son `CHECK-TYPE-MISMATCH`. Una cantidad negativa, o una que daría más de 256 MiB (268435456 bytes), detiene el programa con `RUNTIME-INVALID-COUNT` en la cantidad.

```agentica
def main() -> Void
  puts("ab" * 3)
  puts("=" * 10)
  puts(("x" * 0).empty?)
end
```

```output
ababab
==========
true
```

## include?, start_with? y end_with? {#include-start_with-and-end_with}

```signature
String.include?(string: String, part: String) -> Bool
String.start_with?(string: String, prefix: String) -> Bool
String.end_with?(string: String, suffix: String) -> Bool
```

```agentica
def main() -> Void
  file = "report.txt"
  puts(file.include?("port"))
  puts(file.start_with?("rep"))
  puts(file.end_with?(".csv"))
end
```

```output
true
true
false
```

## replace {#replace}

```signature
String.replace(string: String, from: String, to: String) -> String
```

Reemplaza cada coincidencia.

```agentica
def main() -> Void
  puts("a-b-c".replace("-", "+"))
end
```

```output
a+b+c
```

## slice {#slice}

```signature
String.slice(string: String, start: Int, length: Int) -> String
```

Da `length` caracteres a partir de `start`. Un rango fuera del texto detiene el programa.

```agentica
def main() -> Void
  puts("Agentica".slice(0, 5))
  puts("Agentica".slice(5, 3))
end
```

```output
Agent
ica
```

## index_of {#index_of}

```signature
String.index_of(string: String, part: String) -> Optional[Int]
```

Halla la primera coincidencia como `some(index)`, contada en caracteres (`some(0)` para una parte vacía). Si falta el texto, da `none`.

```agentica
def main() -> Void
  puts("banana".index_of("na"))
  puts("banana".index_of("x").none?)
end
```

```output
some(2)
true
```

## at {#at}

```signature
String.at(string: String, index: Int) -> String
```

Da un carácter. Los índices empiezan en 0. Un índice fuera de la cadena detiene el programa con `RUNTIME-INDEX-OUT-OF-RANGE`.

```agentica
def main() -> Void
  puts("hello".at(1))
end
```

```output
e
```

## reverse {#reverse}

```signature
String.reverse(string: String) -> String
```

```agentica
def main() -> Void
  puts("stressed".reverse)
end
```

```output
desserts
```

## code y from_code {#code-and-from_code}

```signature
String.code(string: String) -> Int
String.from_code(code: Int) -> String
```

`code` da el número Unicode de una cadena de un carácter. `from_code` hace lo contrario, a partir de un valor escalar (de 0 a 0x10FFFF, sin sustitutos). Otra entrada detiene el programa con `RUNTIME-INVALID-CHARACTER`.

```agentica
def main() -> Void
  puts("a".code)
  puts(String.from_code("a".code + 1))
end
```

```output
97
b
```

## compare {#compare}

```signature
String.compare(string: String, other: String) -> Int
```

Da `-1`, `0` o `1`, en el orden que usa `sort`: por punto de código, así que `"B"` va antes que `"a"`. También es un método: `a.compare(b)`.

```agentica
def main() -> Void
  puts("apple".compare("banana"))
  puts("b".compare("b"))
  puts("B".compare("a"))
end
```

```output
-1
0
-1
```

## edit_distance y jaro_winkler {#edit_distance-and-jaro_winkler}

```signature
String.edit_distance(string: String, other: String) -> Int
String.edit_distance(string: String, other: String, max: Int) -> Int
String.jaro_winkler(string: String, other: String) -> Float
```

Los dos miden qué tan parecidos son dos textos, en caracteres como los cuenta `length`, y dan el mismo resultado en cualquier orden. Encuentran el nombre más cercano en una lista, como lo hace una sugerencia «¿quisiste decir?».

`edit_distance` es la distancia de Levenshtein: el menor número de inserciones, quitas y reemplazos de un carácter que convierten `string` en `other`. Tarda un tiempo proporcional a `string.length * other.length`, y usa memoria proporcional al texto más corto. Con `max`, el resultado se detiene en `max + 1`: cuando la distancia supera `max`, el método da `max + 1`. El trabajo es entonces de unas `length * (2 * max + 1)` celdas de la tabla de distancias, en lugar de `string.length * other.length`, con `length` la del texto más largo, y termina pronto cuando la distancia supera `max`, así que un `max` pequeño es rápido en textos largos. Un `max` negativo detiene el programa con `RUNTIME-INVALID-COUNT`. Una llamada larga de cualquiera de los dos métodos deja correr otras tareas entre partes de su trabajo, y `--max-steps` cuenta ese trabajo.

`jaro_winkler` es la similitud de Jaro-Winkler, de `0.0` (nada en común) a `1.0` (el mismo texto), tal como la calcula `DidYouMean::JaroWinkler` de Ruby: cuando la similitud de Jaro es mayor que `0.7`, cada carácter de un prefijo común de hasta 4 suma una décima parte de lo que falta para `1.0`. Dos textos vacíos dan `1.0`, y un texto vacío frente a otro da `0.0`.

```agentica
def main() -> Void
  puts("kitten".edit_distance("sitting"))
  puts("kitten".edit_distance("sitting", 2))
  puts("café".edit_distance("cafe"))
  puts("martha".jaro_winkler("marhta"))
  names = ["length", "upcase", "reverse"]
  puts(names.min_by do |name: String| name.edit_distance("lenght") end)
end
```

```output
3
3
1
0.9611111111111111
some("length")
```

## to_i y to_f {#to_i-and-to_f}

```signature
String.to_i(string: String) -> Result[Int]
String.to_f(string: String) -> Result[Float]
```

Lee un número decimal con signo. Un texto malo da un Result de error. Un número se convierte en texto con [`n.to_s`](/library/text-and-data/numbers/#to_s).

`to_f` también lee un exponente (`1.5E-3`, `1e+20`) y el texto que `to_s` escribe para infinito y NaN (`+inf.0`, `-inf.0`, `+nan.0`), así que `x.to_s.to_f` devuelve `x` (un NaN se lee de vuelta como NaN). Redondea al Float más cercano, y un valor fuera del rango pasa a infinito o cero. `Infinity`, `.5` y `1_000.0` son errores.

```agentica
def main() -> Void
  puts("-12".to_i)
  puts("3.5".to_f)
  puts("1e+20".to_f)
  puts("-inf.0".to_f)
  puts("abc".to_i.ok?)
end
```

```output
ok(-12)
ok(3.5)
ok(1e+20)
ok(-inf.0)
false
```

## to_i! y to_f! {#to_i-and-to_f-1}

```signature
String.to_i!(string: String) -> Int
String.to_f!(string: String) -> Float
```

Igual que `to_i` y `to_f`, pero dan el número mismo y detienen el programa con un texto malo: `RUNTIME-INVALID-NUMBER` para un texto que no es número (`1e`, `.5`, ` 1`, `1_000.0` e `Infinity` para `to_f!`), y `RUNTIME-INTEGER-OVERFLOW` para un entero fuera de `Int`.

```agentica
def main() -> Void
  puts("40".to_i! + 2)
  puts("1.5".to_f! * 2.0)
end
```

```output
42
3.0
```

## from_bytes {#from_bytes}

```signature
String.from_bytes(data: Bytes) -> Result[String]
```

Decodifica bytes UTF-8 de forma estricta: las secuencias no válidas, de longitud excesiva, de sustitutos o incompletas dan un Result de error, nunca caracteres de reemplazo ([`b.scrub`](/library/data-structures/bytes/#scrub) los reemplaza). Es el inverso de [`s.bytes`](#bytes). [`b.decode(encoding)`](/library/data-structures/bytes/#decode) lee las otras codificaciones.

```agentica
def main() -> Void
  puts(String.from_bytes("hi".bytes))
  puts(String.from_bytes(Bytes.from_list([255]).unwrap!).ok?)
end
```

```output
ok("hi")
false
```

## bytes {#bytes}

```signature
String.bytes(string: String) -> Bytes
```

Codifica el texto como UTF-8, como un [`Bytes`](/library/data-structures/bytes/). No puede fallar, y `String.from_bytes` lo convierte de vuelta en texto. `s.bytes.to_a` da los bytes como una lista de enteros de 0 a 255.

```agentica
def main() -> Void
  b = "hé".bytes
  puts(b.length)
  puts(b.to_a)
end
```

```output
3
[104, 195, 169]
```

## encode {#encode}

```signature
String.encode(string: String, encoding: String) -> Result[Bytes]
```

Escribe el texto como bytes en una codificación, con el nombre que se usa en [`Bytes.decode`](/library/data-structures/bytes/#decode): UTF-8, UTF-16, UTF-32, ASCII, Latin-1, ISO-8859-15 o Windows-1252. Las formas simples `utf-16` y `utf-32` escriben una marca de orden de bytes y luego unidades big-endian; las formas `le` y `be` no escriben marca. Un carácter que una codificación de un byte no puede contener (`€` en Latin-1, `¤` en ISO-8859-15) da un Result de error cuyo texto termina con su índice en el texto, `at index N`, y un nombre desconocido también da un error. Las codificaciones Unicode nunca fallan. Para UTF-8, usa [`.bytes`](#bytes) y [`String.from_bytes`](#from_bytes).

```agentica
def main() -> Void
  puts("hé".encode("utf-16le").unwrap!.to_a)
  puts("hé".encode("utf-16").unwrap!.to_a)
  puts("hé".encode("latin-1").unwrap!.to_a)
  puts("h€".encode("latin-1"))
end
```

```output
[104, 0, 233, 0]
[254, 255, 0, 104, 0, 233]
[104, 233]
error("cannot encode U+20AC in Latin-1 at index 1", kind: "text.encoding")
```

## bytesize {#bytesize}

```signature
String.bytesize(string: String) -> Int
```

Cuenta los bytes UTF-8 del texto, incluido el NUL (`"é".bytesize` es 2), tantos como da `s.bytes`, sin crearlos. Una función de C que recibe texto con su longitud obtiene este conteo, con el texto en un búfer de [`Native.from_string`](/library/io-and-system/native/types/#owned-buffers-and-typed-memory).

```agentica
def main() -> Void
  puts("hello".bytesize)
  puts("café".bytesize)
  puts("".bytesize)
end
```

```output
5
5
0
```
