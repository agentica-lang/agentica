---
title: Term (CBOR)
weight: 15
description: Escribe un valor de Agentica como CBOR y lo lee de vuelta en una estructura o un enum, una forma binaria compacta que conserva claves Int, los bits exactos de un Float, nil, Bytes y enums.
source_hash: "66d50ae2bb85"
---

`Term.encode` escribe un valor como bytes [CBOR](https://www.rfc-editor.org/rfc/rfc8949), la forma binaria de un valor. JSON sirve para otros programas; CBOR conserva lo que JSON pierde o deforma: un `Map` con claves `Int`, los bits exactos de un `Float` (infinitos incluidos), `nil` como valor propio, `Bytes` y un enum como un arreglo simple. También es más pequeño. Usos típicos son un caché en disco y los mensajes entre programas de Agentica. `Term.decode` lee los bytes de vuelta en el tipo que nombras: el tipo es el esquema, así que nunca se construye nada fuera de él.

```signature
Term.encode(value: T) -> Result[Bytes]
Term.decode(data: Bytes, type: T) -> Result[T]
```

`Term` es un nombre reservado de tipo y de módulo, así que una estructura, un enum o un alias no pueden llevarlo (`CHECK-REDEFINED-NAME`).

```agentica
struct Entry
  hits: Map[Int, Int]
  score: Float
end

def main() -> Void
  entry = Entry(hits: {2: 5, 1: 7}, score: 1.5)
  bytes = Term.encode(entry).unwrap!
  puts(OpenSSL.Digest.hexencode(bytes))
  puts(Term.decode(bytes, Entry).unwrap!.hits)
end
```

```text
a26468697473a2020501076573636f7265fb3ff8000000000000
{2: 5, 1: 7}
```

Los bytes son un mapa de dos entradas: la clave `"hits"` con un mapa de `2` a `5` y de `1` a `7` (en el orden en que se pusieron), y la clave `"score"` con un flotante de 8 bytes.

## Qué escribe {#what-it-writes}

| Agentica | CBOR |
|---|---|
| `Int`, `Int8` a `Int32`, `UInt8` a `UInt32` | un entero (tipo mayor 0 o 1) en la menor cantidad de bytes |
| `UInt64` | un entero de `0` a `18446744073709551615` |
| `Float` | siempre un flotante de 64 bits. Todo NaN se escribe como el NaN silencioso `0x7FF8000000000000`; `-0.0` y los infinitos conservan sus bits |
| `Float32` | siempre un flotante de 32 bits; todo NaN es `0x7FC00000` |
| `String` | una cadena de texto (UTF-8) |
| `Bytes` | una cadena de bytes |
| `Bool`, `nil` | `false`, `true` y `null` |
| `List[T]` | un arreglo |
| `Map[K, V]` | un mapa en orden de inserción. `K` es `Int` o `String`; un entero con tamaño o un `UInt64` como clave es `CHECK-NOT-ENCODABLE` |
| estructura | un mapa del nombre del campo al valor, en el orden de la declaración |
| enum | el arreglo `[tag, [values...]]`: `tag` es el nombre de la variante sin el nombre del enum, y `values` tiene los payloads, `["Empty", []]` para una variante sin ninguno |
| `Optional[T]` | `null` para `none`, el valor para `some`. `Optional[Nil]` y un `Optional` de un `Optional` se rechazan: no se podrían distinguir |

`JSON.Field[T]` es aquí un enum simple, `[tag, [values...]]` con los tags `Absent`, `Null` y `Value`, y puede estar donde puede estar un tipo. Una estructura o un enum genérico se escribe por sus campos con los argumentos de tipo puestos. Todo otro tipo es `CHECK-NOT-ENCODABLE`, con el span en el argumento: una función, un `Set`, un `Result`, un `Void`, `JSON.Value`, las fechas y horas de `Time`, un `Range` y todos los handles (`File.Handle`, `Process`, `TCP.Socket`, una `Task`, un `Channel` y los demás), a cualquier profundidad. El argumento tiene un tipo concreto: una variable de tipo de una función genérica también se rechaza. Un campo privado de una estructura de otro módulo es `CHECK-PRIVATE-FIELD`, como en `JSON.encode`.

## Mismo valor, mismos bytes {#same-value-same-bytes}

La forma es determinista (RFC 8949 sección 4.2): la cabecera más corta de cada elemento, y longitudes que siempre se conocen. Dos reglas de esa sección no se siguen a propósito: las claves de un mapa conservan el orden de inserción, porque un `Map` de Agentica está ordenado y el orden es parte de su valor, y los flotantes siempre ocupan su ancho completo, así que un `Float` nunca vuelve como un `Int` y sus bits son exactos.

## Límites {#limits}

`Term.encode` es para datos, no para entradas sin límite. Devuelve un `error` con la ruta del primer valor que cruza un límite, y deja de escribir ahí; nunca se detiene con un halt por ellos.

- **Profundidad:** como máximo 10,000 niveles. Una estructura, una `List`, un `Map` y un enum son un nivel cada uno (un enum es un nivel aunque sean dos arreglos CBOR); un `Optional` no añade ninguno.
- **Valores:** como máximo 4,000,000 valores en total. La clave de un `Map` cuenta como un valor y el nombre de un campo no.
- **Tamaño:** como máximo 64 MiB de salida.

El mensaje es `ruta: motivo`, con la ruta de los errores de `JSON.decode`: la raíz es `$`, un campo es `by_name`, un índice `[3]`, una clave `Int` `[3]`, una clave `String` `["k"]` (cortada a 64 bytes, con `...` después del corte), y un payload de un enum `values[0]`:

```text
items[0].values[0][3999996]: more than 4000000 values
$: larger than 67108864 bytes
```

La clase del error es `term.encode` (consulta los [errores](/library/errors/error/)). Para más datos, codifícalos en trozos, cada uno como su propio valor.

## Term.decode {#term-decode}

`Term.decode(data, Name)` lee los bytes en la estructura o el enum `Name` y devuelve `ok(value)`, o un `error` con la ruta del primer valor malo. El segundo argumento es un nombre de tipo, como en `JSON.decode(text, User)`: una estructura o un enum con nombre, así que una `List`, un `Map` o una instancia de una estructura genérica como `Box[Int]` no es un destino (`CHECK-TYPE-MISMATCH`); ponlo en un campo de una estructura. Todo lo de dentro del destino sigue la tabla de arriba, y una instancia de estructura genérica sirve como campo.

`Term.encode` acepta más de lo que `Term.decode` puede tomar como destino, como `JSON.encode` frente a `JSON.decode`: escribe una `List`, un `Map` o una instancia de un enum genérico como valor completo, y una estructura con un enum genérico dentro. `Term.decode` toma solo una estructura o un enum con nombre como destino, y un enum genérico en cualquier parte de dentro es `CHECK-NOT-DECODABLE`, con el span en el nombre del tipo. Para leer esos datos de vuelta, usa un enum simple o una estructura, y pon una `List` o un `Map` en un campo.

```agentica
enum Shape
  Circle(Float)
  Empty
end

def main() -> Void
  bytes = Term.encode(Shape.Circle(1.5)).unwrap!
  case Term.decode(bytes, Shape)
    ok(shape) -> puts(shape)
    error(e) -> puts(e.message)
  end
end
```

Nunca hay una lectura sin tipo: los bytes no pueden nombrar un tipo para construir, y no se puede pedir una función, un handle ni una estructura sin límite.

- **El mismo valor de vuelta:** `Term.decode(Term.encode(v), T)` da `v` para todo tipo que `Term.encode` escribe. `Term.encode(Term.decode(bytes, T))` devuelve `bytes` solo cuando `bytes` es lo que `Term.encode` escribe.
- **Solo lo que `Term.encode` escribe:** una cabecera más larga de lo necesario, una longitud indefinida, un tag, un medio flotante, un flotante con el ancho de otro tipo (`Float` lee 8 bytes, `Float32` 4), un NaN con payload, texto que no es UTF-8, una clave de `Map` repetida y bytes después del valor son errores. Un `Int` fuera de 64 bits es un error, y también un valor fuera del rango de un `Int8` a `UInt32`.
- **Estructuras:** las claves pueden venir en cualquier orden y una clave que no nombra ningún campo se lee y se ignora (con las mismas comprobaciones y los mismos límites). Un campo nombrado dos veces y un campo que falta son errores: el valor por defecto de un campo solo rellena un constructor, así que **añadir un campo rompe los datos viejos**. Quitar o reordenar campos es seguro.
- **Enums:** un tag desconocido, una lista de payloads de otra longitud y un arreglo exterior que no es de dos elementos son errores.

Los límites son los de `Term.encode`: 10,000 niveles, 4,000,000 valores y 64 MiB, y un valor que pasa uno devuelve un error como allí. La entrada se lee con el mismo cuidado que un archivo de bytecode: cada longitud se comprueba contra los bytes que quedan antes de construir nada, así que unos pocos bytes no pueden pedir mucha memoria. La clase del error es `term.decode`, y la ruta tiene la misma forma: `users[2].name: expected String`, `shapes[1]: unknown tag "Triangle"`, `$: trailing bytes after the value`, `x: expected signed 64-bit Int`. Donde el tipo es un `Optional`, el tipo esperado va seguido de `or nil`.

## Versiones y marcos {#versioning-and-framing}

Los bytes no llevan versión ni tipo: el tipo es el esquema. Pon un campo `version: Int` en la estructura de arriba desde la primera versión. Para añadir un campo, conserva la estructura vieja (`CacheV1`) junto a la nueva (`CacheV2`): decodifica con `CacheV2`, y si da error decodifica de nuevo con `CacheV1` y convierte.

`Term.decode` rechaza los bytes después del valor, así que un flujo necesita marcos: una longitud de 4 bytes big-endian (`std/binary`), y luego los bytes en trozos de como máximo 1 MiB (el límite de `Process.send_bytes` y `TCP.send_bytes`). El receptor rechaza una longitud por encima de su límite antes de leer el cuerpo.

## Lo que no se admite {#not-supported}

Una `Fn` y un handle (un handle solo vale dentro de la ejecución que lo creó), una lectura sin tipo, y los mensajes transparentes de la distribución de Erlang: los programas hablan por pipes o TCP con `Term.encode` y `Term.decode` explícitos, así que un fallo es un `Result` que el programa ve.
