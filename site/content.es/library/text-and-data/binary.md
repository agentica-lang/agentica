---
title: Datos binarios (std)
weight: 4
description: El módulo std/binary, que lee y escribe números en formato binario en un Bytes.
source_hash: "dd44769f55ae"
---

`std/binary` está escrito en Agentica, sobre las funciones de bits de [Int y Float](/library/text-and-data/numbers/). Impórtalo: `import Binary from "std/binary"`.

Los datos binarios son un [`Bytes`](/library/data-structures/bytes/), como el que dan `IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` y `Process.read_bytes`. Cada función tiene el [tipo con tamaño](/library/text-and-data/numbers/#int8-int16-int32-uint8-uint16-and-uint32) de su ancho: `read_u16_be` da un `UInt16`, `write_i32_le` recibe un `Int32`. Una función de lectura recibe el `Bytes` y un desplazamiento (`offset`) que empieza en cero; su único error es un desplazamiento fuera de los datos. Una función de escritura recibe un valor de su tipo, así que no puede fallar, y devuelve un `Bytes` nuevo.

```agentica
import Binary from "std/binary"

def main() -> Void
  header = Binary.write_u16_be(513)
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
Binary.read_<T>(data: Bytes, offset: Int) -> Result[<type of T>]
Binary.read_<F>(data: Bytes, offset: Int) -> Result[Float]
```

`<T>` es `u8` o `i8`, o `u16`, `i16`, `u32`, `i32`, `u64`, `i64` seguido de `_be` o `_le`, y su tipo es `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64` e `Int` (`i64` es el `Int`). `<F>` es `f32` o `f64` seguido de `_be` o `_le`.

Una función de lectura nunca detiene el programa: un desplazamiento malo da un `error(...)` (ver Errores). El `offset` puede ser cualquier `Int`. `x.to_i` da el `Int` de un valor estrecho cuando necesitas contar con él.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = Bytes.from_list([1, 2, 3, 4, 255, 254]).unwrap!
  puts(Binary.read_u8(data, 4)) # one byte, a UInt8
  puts(Binary.read_i8(data, 4)) # the same byte, an Int8
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
Binary.write_<T>(value: <type of T>) -> Bytes
Binary.write_<F>(value: Float) -> Bytes
```

`<T>` y sus tipos son los de las funciones de lectura. `<F>` es `f32` o `f64` seguido de `_be` o `_le`. Una función de escritura devuelve un `Bytes` nuevo con exactamente los bytes de su tipo; un `Bytes` nunca cambia en su sitio.

- Ninguna función de escritura falla ni devuelve un `Result`, así que un `try` sobre ellas es un error de comprobación. Un literal toma el tipo del parámetro (`Binary.write_u16_be(513)`); un valor que puede quedar fuera del tipo se convierte antes, donde el error se puede tratar: `try n.to_uint16`.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_u16_be(513).to_a)
  puts(Binary.write_u16_le(513).to_a)
  puts(Binary.write_u32_be(305419896).to_a)
  puts(Binary.write_i64_be(-1).to_a)
  puts(Binary.write_i32_le(-2).to_a)
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

`f64` usa `Float.to_bits` y `Float.from_bits`, que leen los 64 bits como un `UInt64`. `f32` es un [`Float32`](/library/text-and-data/numbers/#float32): `read_f32_*` da uno y `write_f32_*` recibe uno (`x.to_float32` redondea un `Float` al más cercano). `-0.0`, los infinitos y los subnormales se conservan, y cada NaN se escribe como el NaN canónico.

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
ok(0.1)
ok(3.141592653589793)
true
```

## u64 y i64 {#u64-and-i64}

`read_u64_*` da un `UInt64`, que guarda todo `0` a `18446744073709551615`; `read_i64_*` lee los mismos bytes como un `Int`, negativo cuando el bit más alto está activado. Cada `ok` de una función de lectura de enteros se escribe de vuelta en los mismos bytes; también una de flotantes, salvo que un patrón de NaN distinto del canónico vuelve como canónico.

```agentica
import Binary from "std/binary"

def main() -> Void
  top = Bytes.from_list([128, 0, 0, 0, 0, 0, 0, 0]).unwrap!
  puts(Binary.read_u64_be(top, 0))
  puts(Binary.read_i64_be(top, 0))
  puts(Binary.write_u64_be(18446744073709551615).to_a)
end
```

```output
ok(9223372036854775808)
ok(-9223372036854775808)
[255, 255, 255, 255, 255, 255, 255, 255]
```

Las funciones de escritura devuelven valores nuevos, y ningún búfer cambia nunca. Las escrituras con desplazamiento sobre un `Bytes` existente no forman parte del módulo. Los flotantes de media precisión (f16) y los enteros de longitud variable (LEB128) no se admiten; el hexadecimal y Base64 son los integrados `OpenSSL.Digest` y `Base64`. Las operaciones de bits y las conversiones de bits de `Float` son integrados de `Int` y `Float`, porque en Agentica cada una es un bucle de 64 bits o un escalado exacto por potencias de dos, con casos especiales para `-0.0`, NaN y subnormales.

## Unir {#joining}

Para unir resultados de escritura, usa `Bytes.concat(parts)`: una sola copia para cualquier número de partes. Crea `parts` con `map`; un bucle con `+` copia toda la salida en cada iteración, O(n²).

```agentica
import Binary from "std/binary"

def main() -> Void
  ids: List[Int32] = [1, 258, 65536]
  parts = ids.map do |id: Int32| Binary.write_i32_be(id) end
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
| `frame` con más de `4294967295` bytes | `payload of 4294967296 bytes does not fit in a u32 length` |
| `read_frame_length` con una longitud mayor que `max` | `frame length 70000 is above the limit 65536` |

El tipo que aparece en un mensaje es el del nombre de la función.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = Bytes.from_list([0, 0, 1, 44]).unwrap!
  puts(Binary.read_u32_be(data, 1))
  puts(Binary.read_u16_be(data, -1))
  puts(Binary.read_u8(data, 4))
end
```

```output
error("u32 at offset 1 is outside bytes of length 4", kind: "argument")
error("u16 at offset -1 is outside bytes of length 4", kind: "argument")
error("u8 at offset 4 is outside bytes of length 4", kind: "argument")
```
