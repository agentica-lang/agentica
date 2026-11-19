---
title: Datos binarios (std)
weight: 4
description: El módulo std/binary, que lee y escribe números binarios en un Bytes.
source_hash: "d6d04e3ee42c"
---

`std/binary` está escrito en Agentica, sobre las funciones de bits de [Int y Float](/library/text-and-data/numbers/). Impórtalo: `import Binary from "std/binary"`.

Los datos binarios son un [`Bytes`](/library/data-structures/bytes/), como el que dan `IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` y `Process.read_bytes`. Una función de lectura recibe el `Bytes` y un desplazamiento (`offset`) que empieza en cero; su único error es un desplazamiento fuera de los datos. Una función de escritura devuelve un `Bytes` nuevo.

```agentica
import Binary from "std/binary"

def main() -> Void
  header = Binary.write_u16_be(513).unwrap!
  body = Binary.write_f64_le(1.5)
  data = Bytes.concat([header, body])
  puts(data.to_a)
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_f64_le(data, 2))
end
```

```output
[2, 1, 0, 0, 0, 0, 0, 0, 248, 63]
ok(513)
ok(1.5)
```

`_be` es big-endian (orden de red), `_le` es little-endian. Los tipos con signo usan complemento a dos.

## Lectura {#readers}

```signature
Binary.read_<T>(data: Bytes, offset: Int) -> Result[Int]
Binary.read_<F>(data: Bytes, offset: Int) -> Result[Float]
```

`<T>` es `u8` o `i8`, o `u16`, `i16`, `u32`, `i32`, `u64`, `i64` seguido de `_be` o `_le`. `<F>` es `f32` o `f64` seguido de `_be` o `_le`.

Una función de lectura nunca detiene el programa: un desplazamiento malo o un `u64` con el bit más alto activado dan un `error(...)` (ver Errores). El `offset` puede ser cualquier `Int`.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = Bytes.from_list([1, 2, 3, 4, 255, 254]).unwrap!
  puts(Binary.read_u8(data, 4)) # one byte, unsigned
  puts(Binary.read_i8(data, 4)) # the same byte, signed
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_u16_le(data, 0))
  puts(Binary.read_u32_be(data, 0))
  puts(Binary.read_i16_le(data, 4))
end
```

```output
ok(255)
ok(-1)
ok(258)
ok(513)
ok(16909060)
ok(-257)
```

## Escritura {#writers}

```signature
Binary.write_<T>(value: Int) -> Result[Bytes]
Binary.write_<I64>(value: Int) -> Bytes
Binary.write_<F>(value: Float) -> Bytes
```

`<T>` es `u8` o `i8`, o `u16`, `i16`, `u32`, `i32`, `u64` seguido de `_be` o `_le`. `<I64>` es `i64_be` o `i64_le`. `<F>` es `f32` o `f64` seguido de `_be` o `_le`. Una función de escritura devuelve un `Bytes` nuevo con exactamente los bytes de su tipo; un `Bytes` nunca cambia en su sitio.

- Solo las funciones `<T>` de escritura devuelven un `Result`, ya que el valor puede estar fuera del tipo. `write_i64_*` y las de flotantes no pueden fallar y devuelven un `Bytes` simple, así que un `try` sobre ellas es un error de comprobación.
- Rangos: `u8` de 0 a 255, `i8` de -128 a 127, `u16` de 0 a 65535, `i16` de -32768 a 32767, `u32` de 0 a 4294967295, `i32` de -2147483648 a 2147483647, `u64` de 0 a 9223372036854775807.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_u16_be(513).unwrap!.to_a)
  puts(Binary.write_u16_le(513).unwrap!.to_a)
  puts(Binary.write_u32_be(305419896).unwrap!.to_a)
  puts(Binary.write_i64_be(-1).to_a) # a plain Bytes, it cannot fail
  puts(Binary.write_i32_le(-2).unwrap!.to_a)
end
```

```output
[2, 1]
[1, 2]
[18, 52, 86, 120]
[255, 255, 255, 255, 255, 255, 255, 255]
[254, 255, 255, 255]
```

## Flotantes {#floats}

`f64` usa `Float.to_bits` y `Float.from_bits`. `write_f32_*` redondea al binary32 más cercano (`Float.to_bits32`); `read_f32_*` lo amplía de vuelta exactamente. `-0.0`, los infinitos y los subnormales se conservan, y cada NaN se escribe como el NaN canónico.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_f32_be(1.0).to_a)
  puts(Binary.write_f64_be(1.0).to_a)
  puts(Binary.write_f32_le(0.1).to_a)
  puts(Binary.read_f32_le(Binary.write_f32_le(0.1), 0))
  puts(Binary.read_f64_be(Bytes.from_list([64, 9, 33, 251, 84, 68, 45, 24]).unwrap!, 0))
  puts(Binary.read_f32_be(Bytes.from_list([127, 128, 0, 0]).unwrap!, 0).unwrap! > 1.0)
end
```

```output
[63, 128, 0, 0]
[63, 240, 0, 0, 0, 0, 0, 0]
[205, 204, 204, 61]
ok(0.10000000149011612)
ok(3.141592653589793)
true
```

## u64 y i64 {#u64-and-i64}

Un `u64` mayor que `9223372036854775807` no es un `Int`: `read_u64_*` da un error y `write_u64_*` rechaza un valor negativo. Para los 64 bits completos usa `read_i64_*` y `write_i64_*`. Cada `ok` de una función de lectura de enteros se escribe de vuelta en los mismos bytes; también una de flotantes, salvo que un patrón de NaN distinto del canónico vuelve como canónico.

```agentica
import Binary from "std/binary"

def main() -> Void
  top = Bytes.from_list([128, 0, 0, 0, 0, 0, 0, 0]).unwrap!
  puts(Binary.read_u64_be(top, 0))
  puts(Binary.read_i64_be(top, 0))
  puts(Binary.write_u64_be(-1))
  puts(Binary.write_u64_be(9223372036854775807).unwrap!.to_a)
end
```

```output
error("u64 at offset 0 does not fit in Int", kind: "number.range")
ok(-9223372036854775808)
error("value -1 does not fit in u64", kind: "argument")
[127, 255, 255, 255, 255, 255, 255, 255]
```

Las funciones de escritura devuelven valores nuevos, y ningún búfer cambia nunca. Las escrituras con desplazamiento sobre un `Bytes` existente no forman parte del módulo. Los flotantes de media precisión (f16) y los enteros de longitud variable (LEB128) no se admiten; el hexadecimal y Base64 son los integrados `OpenSSL.Digest` y `Base64`. Las operaciones de bits y las conversiones de bits de `Float` son integrados de `Int` y `Float`, porque en Agentica cada una es un bucle de 64 bits o un escalado exacto por potencias de dos, con casos especiales para `-0.0`, NaN y subnormales.

## Unir {#joining}

Para unir resultados de escritura, usa `Bytes.concat(parts)`: una sola copia para cualquier número de partes. Crea `parts` con `map`; un bucle con `+` copia toda la salida en cada iteración, O(n²).

```agentica
import Binary from "std/binary"

def main() -> Void
  ids = [1, 258, 65536]
  parts = ids.map do |id| Binary.write_i32_be(id).unwrap! end
  puts(Bytes.concat(parts).to_a)
  puts(Bytes.concat([]).to_a)
end
```

```output
[0, 0, 0, 1, 0, 0, 1, 2, 0, 1, 0, 0]
[]
```

## Enmarcado {#framing}

```signature
Binary.frame(payload: Bytes) -> Result[Bytes]
Binary.read_frame_length(data: Bytes, offset: Int, max: Int) -> Result[Int]
```

`frame` antepone al payload su longitud de 4 bytes en big-endian (un error por encima de `4294967295` bytes). `read_frame_length` rechaza una longitud mayor que `max` antes de leer el cuerpo. Lee tú mismo el cuerpo en un bucle: `TCP.recv_bytes` y `Process.read_bytes` pueden devolver menos bytes de los pedidos.

```agentica
import Binary from "std/binary"

def main() -> Void
  framed = Binary.frame("hi".bytes).unwrap!
  puts(framed.to_a)
  puts(Binary.read_frame_length(framed, 0, 65536))
  puts(Binary.read_frame_length(Bytes.from_list([0, 1, 17, 112]).unwrap!, 0, 65536))
  puts(Binary.read_frame_length(framed, 0, -1))
end
```

```output
[0, 0, 0, 2, 104, 105]
ok(2)
error("frame length 70000 is above the limit 65536", kind: "binary.too_large")
error("frame limit -1 is negative", kind: "argument")
```

## Errores {#errors}

Cada problema es un `error(message)`. Una función comprueba estos casos en orden y devuelve el primero que aplique:

| Caso | Mensaje |
|---|---|
| `read_frame_length` con un `max` negativo | `frame limit -1 is negative` |
| `offset` menor que 0 o mayor que `data.size - n` (cualquier `Int`) | `u32 at offset 10 is outside bytes of length 12` |
| `read_u64_*` con el bit más alto activado | `u64 at offset 0 does not fit in Int` |
| el valor de una función de escritura fuera de su tipo | `value 70000 does not fit in u16` |
| `frame` con más de `4294967295` bytes | `payload of 4294967296 bytes does not fit in a u32 length` |
| `read_frame_length` con una longitud mayor que `max` | `frame length 70000 is above the limit 65536` |

El tipo que aparece en un mensaje es el del nombre de la función.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = Bytes.from_list([0, 0, 1, 44]).unwrap!
  puts(Binary.read_u32_be(data, 1))
  puts(Binary.read_u16_be(data, -1))
  puts(Binary.write_u8(256))
  puts(Binary.write_i16_le(-32769))
end
```

```output
error("u32 at offset 1 is outside bytes of length 4", kind: "argument")
error("u16 at offset -1 is outside bytes of length 4", kind: "argument")
error("value 256 does not fit in u8", kind: "argument")
error("value -32769 does not fit in i16", kind: "argument")
```
