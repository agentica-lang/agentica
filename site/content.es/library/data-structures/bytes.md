---
title: Bytes
weight: 7
description: Bytes, una cadena de bytes compacta e inmutable, y los métodos que la leen, la cortan, la unen y la construyen.
source_hash: "6e66f925565d"
---

`Bytes` guarda datos que no son texto: resúmenes criptográficos, contenido de archivos, formatos de red. Guarda un byte por cada elemento, mientras que una `List[Int]` con los mismos datos ocupa ocho. Un byte se lee como un `Int` de 0 a 255. `Bytes` es inmutable, como todos los valores: un método da un valor nuevo. `Bytes` es un nombre reservado, así que una estructura, un enum o un alias de importación no puede llamarse `Bytes`.

No hay literal. Crea un valor con `s.bytes` (los bytes UTF-8 de una `String`), [`OpenSSL.Digest.hexdecode`](/library/text-and-data/base64/#hex) o `Bytes.from_list`. `"text".bytes` sobre un literal de cadena sin interpolación es una constante, creada una vez al cargar el programa, así que escribirla dentro de un bucle cuesta lo mismo que una constante con nombre, y puede ser un predeterminado: `body: Bytes = "".bytes`. Los datos binarios que no son texto UTF-8 vienen de `Bytes.from_list` o de `OpenSSL.Digest.hexdecode`.

```agentica
def main() -> Void
  data = "héllo".bytes
  puts(data.length)
  puts(data[0])
  puts(data.to_a)
end
```

```output
6
104
[104, 195, 169, 108, 108, 111]
```

Dos `Bytes` son iguales cuando tienen la misma longitud y los mismos bytes. `==` no es de tiempo constante, así que compara un MAC o un token con [`OpenSSL.HMAC.secure_compare`](/library/text-and-data/crypto/). Un `Bytes` nunca es igual a una `String`. No hay `<`. Un `Bytes` puede ser una clave de `Map`, una clave de `ATS` o un elemento de `Set`, así que una caché puede usar un resumen como clave. No es JSON: `JSON.encode` y `JSON.decode` lo rechazan con `CHECK-NOT-ENCODABLE` y `CHECK-NOT-DECODABLE`; conviértelo antes a texto con `Base64.strict_encode64`. `List.uniq`, `tally` y `group_by` aceptan elementos o claves `Bytes`.

```agentica
def main() -> Void
  a = "abc".bytes
  puts(a == "abc".bytes)
  puts(a != "abd".bytes)
  seen = Set.new([a, "abc".bytes, "xyz".bytes])
  puts(seen.size)
  puts(a)
  puts(a.inspect)
end
```

```output
true
true
2
<Bytes 3>
<Bytes 3 616263>
```

`to_s` y la interpolación dan `<Bytes 3>`, solo la longitud, porque los bytes crudos no son texto. `inspect` y el texto de un `Bytes` dentro de una lista o de un mapa también muestran los primeros 32 bytes en hexadecimal, y luego `...` si hay más.

## bytes {#bytes}

`s.bytes` ([String.bytes](/library/text-and-data/string/#bytes)) da los bytes UTF-8 del texto. `Bytes` no tiene `chars`: `s.bytes.to_a` es la lista de enteros.

## decode {#decode}

```signature
Bytes.decode(bytes: Bytes, encoding: String) -> Result[String]
```

Lee los bytes como texto en una codificación: `utf-8`, `utf-16`, `utf-16le`, `utf-16be`, `utf-32`, `utf-32le`, `utf-32be`, `ascii`, `latin-1` (ISO-8859-1), `iso-8859-15` (Latin-9, con el signo del euro) o `windows-1252`. Un nombre se compara sin distinguir mayúsculas, con `_` leído como `-`, y también sirven estos alias: `utf8`, `utf16`, `utf32`, `utf-16-le`, `utf-16-be`, `utf-32-le`, `utf-32-be`, `us-ascii`, `latin1`, `iso-8859-1`, `iso8859-1`, `l1`, `cp819`, `iso8859-15`, `latin9`, `l9` y `cp1252`. Un nombre desconocido da un Result de error; el paquete `agentica-lang/charset` lee las otras codificaciones. [`text.encode(encoding)`](/library/text-and-data/string/#encode) hace el camino inverso. Para UTF-8, usa [`String.from_bytes`](/library/text-and-data/string/#from_bytes) y [`.bytes`](#bytes), o [`scrub`](#scrub) para reemplazar los bytes malos.

Las formas simples `utf-16` y `utf-32` leen una marca de orden de bytes y la descartan, y leen big-endian cuando no hay ninguna, como dice el estándar Unicode (Python lee el orden de bytes de la máquina). Las formas `le` y `be`, y `utf-8`, conservan una marca como el carácter U+FEFF. La decodificación es estricta: el primer byte o secuencia que la codificación no admite (UTF-8 inválido, un sustituto sin pareja, una unidad de código cortada, un valor por encima de U+10FFFF, un byte mayor que 127 en ASCII, uno de los cinco bytes que Windows-1252 deja sin definir: 0x81, 0x8D, 0x8F, 0x90 y 0x9D) da un Result de error cuyo texto termina con su posición, `at byte N`, contada desde 0. Latin-1 e ISO-8859-15 leen cada byte.

```agentica
def main() -> Void
  data = Bytes.from_list([255, 254, 104, 0, 233, 0]).unwrap!
  puts(data.decode("utf-16"))
  puts(Bytes.from_list([104, 233]).unwrap!.decode("Latin-1"))
  puts(Bytes.from_list([104, 0, 0, 220]).unwrap!.decode("utf-16le"))
  puts("x".bytes.decode("koi8-r").ok?)
end
```

```output
ok("hé")
ok("hé")
error("invalid UTF-16LE at byte 2", kind: "text.encoding")
false
```

## scrub {#scrub}

```signature
Bytes.scrub(bytes: Bytes, replacement: String = "�") -> String
```

Lee los bytes como UTF-8 y nunca falla: cada secuencia inválida o cortada se vuelve el reemplazo, U+FFFD si no se indica otro, y `""` la quita. Sirve para texto que puede tener bytes malos, como un registro (log) o la salida de un proceso hijo; [`String.from_bytes`](/library/text-and-data/string/#from_bytes) es la forma estricta. Un reemplazo representa la parte inicial más larga de una secuencia válida (la «subparte máxima» de Unicode), como en `decode("utf-8", "replace")` de Python y en un navegador: un carácter de 3 bytes cortado da uno, una codificación sobrelarga o un sustituto da uno por byte, y así cada byte por encima de 0xF4. Un registro leído línea a línea nunca corta un carácter, porque una línea termina en el byte 10, que ninguna secuencia de varios bytes contiene.

```agentica
def main() -> Void
  data = Bytes.from_list([104, 226, 130, 105, 255]).unwrap!
  puts(data.scrub)
  puts(data.scrub("?"))
  puts(data.scrub(""))
end
```

```output
h�i�
h?i?
hi
```

## from_list {#from_list}

```signature
Bytes.from_list(list: List[Int]) -> Result[Bytes]
```

Crea un `Bytes` a partir de enteros. Un elemento fuera de 0 a 255 da un error que nombra su índice. Para construir bytes uno a uno, crea una `List[Int]` y llama a `from_list` una vez.

```agentica
def main() -> Void
  puts(Bytes.from_list([80, 75, 3, 4]).unwrap!.inspect)
  puts(Bytes.from_list([1, 256]).message)
end
```

```output
<Bytes 4 504b0304>
item 1 is 256, not a byte (0 to 255)
```

## to_a {#to_a}

```signature
Bytes.to_a(bytes: Bytes) -> List[Int]
```

Los bytes como lista de enteros. `Bytes` no tiene `map`, `select` ni `reduce`; `to_a` es el camino hacia ellos, y cuesta ocho bytes de memoria por cada byte.

```agentica
def main() -> Void
  total = "abc".bytes.to_a.reduce(0) do |sum, byte| sum + byte end

  puts(total)
end
```

```output
294
```

## length y empty? {#length-and-empty}

```signature
Bytes.length(bytes: Bytes) -> Int
Bytes.empty?(bytes: Bytes) -> Bool
```

El número de bytes, y si no hay ninguno. `size` es igual que `length`.

## at {#at}

```signature
Bytes.at(bytes: Bytes, index: Int) -> Int
```

El byte en un índice de base cero, como `b.at(i)` o `b[i]`. Un índice fuera de los bytes detiene el programa con `RUNTIME-INDEX-OUT-OF-RANGE`.

```agentica
def main() -> Void
  b = "AZ".bytes
  puts(b[0])
  puts(b.at(1))
end
```

```output
65
90
```

## slice, take y drop {#slice-take-and-drop}

```signature
Bytes.slice(bytes: Bytes, start: Int, length: Int) -> Bytes
Bytes.take(bytes: Bytes, count: Int) -> Bytes
Bytes.drop(bytes: Bytes, count: Int) -> Bytes
```

`slice` copia un rango y detiene el programa fuera de los límites. `take` y `drop` copian los primeros `count` bytes o el resto, y nunca se detienen por un conteo mayor que la longitud (un conteo negativo es `RUNTIME-INVALID-COUNT`). Las tres copian: un resultado no mantiene viva su fuente.

```agentica
def main() -> Void
  b = "abcdef".bytes
  puts(b.slice(1, 3).to_a)
  puts(b.take(2).to_a)
  puts(b.drop(4).to_a)
  puts(b.take(99).length)
end
```

```output
[98, 99, 100]
[97, 98]
[101, 102]
6
```

## + y concat {#-and-concat}

```text
a + b
Bytes.concat(list: List[Bytes]) -> Bytes
```

`+` une dos valores. Un `+` repetido copia todo cada vez, así que un bucle que une muchas partes tarda tiempo cuadrático; une las partes con `Bytes.concat`, que copia una vez. Un encadenamiento como `a + b + c` en una sola expresión, y `Bytes.concat` de una lista literal de hasta 8 elementos, también copian una vez y no crean lista.

```agentica
def main() -> Void
  puts(("ab".bytes + "cd".bytes).to_a)
  puts(Bytes.concat(["a".bytes, "b".bytes, "c".bytes]).to_a)
end
```

```output
[97, 98, 99, 100]
[97, 98, 99]
```

## build {#build}

```signature
Bytes.build(block: Fn[Bytes.Builder, Void]) -> Bytes
out.write(value, ...) -> Void
```

Crea un solo `Bytes` a partir de muchas partes pequeñas, como una respuesta de un protocolo de red. `Bytes.build` llama al bloque con un `Bytes.Builder`, `out`, y devuelve lo que el bloque escribió. `out.write` toma de 1 a 8 valores y añade cada uno: un `Bytes` o una `String` como sus bytes, un `Int`, un `Float`, un `Bool` o `nil` como el texto que les da la interpolación (sin crear una `String` para ellos), y cualquier otro valor como su `to_s`. El búfer crece cuando hace falta y se copia una vez al resultado; una tarea guarda un búfer de hasta 64 KiB para su próxima construcción, así que una construcción dentro de un bucle asigna poca memoria aparte de su resultado. Cada tarea conserva ese búfer reutilizable hasta que termina.

`out` solo funciona dentro de su bloque y en la tarea que lo ejecuta. Una escritura después de que el bloque terminó (el constructor se envió por un canal), o desde otra tarea, detiene el programa con `RUNTIME-BUILDER-CLOSED`, así que un `Bytes` que devolvió `build` nunca cambia.

```agentica
def reply(items: List[Bytes]) -> Bytes
  Bytes.build do |out|
    out.write("*", items.size, "\r\n")
    for item in items
      out.write("$", item.size, "\r\n", item, "\r\n")
    end
  end
end

def main() -> Void
  puts(reply(["GET".bytes, "key".bytes]).to_a.size)
  puts(String.from_bytes(reply(["ok".bytes])).unwrap!.inspect)
end
```

```output
22
"*1\r\n$2\r\nok\r\n"
```

## each y for {#each-and-for}

```signature
Bytes.each(bytes: Bytes, block: Fn[Int, Void]) -> Void
```

Llama al bloque con cada byte en orden. `for byte in b` hace lo mismo y permite asignar en el cuerpo.

```agentica
def main() -> Void
  sum = 0
  for byte in "abc".bytes
    sum += byte
  end

  puts(sum)
  "ab".bytes.each do |byte| puts(byte) end
end
```

```output
294
97
98
```
