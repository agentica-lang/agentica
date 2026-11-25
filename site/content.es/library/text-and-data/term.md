---
title: Term (CBOR)
weight: 15
description: Escribe un valor de Agentica como CBOR, una forma binaria compacta que conserva claves Int, los bits exactos de un Float, nil, Bytes y enums.
source_hash: "8e906b08040d"
---

`Term.encode` escribe un valor como bytes [CBOR](https://www.rfc-editor.org/rfc/rfc8949), la forma binaria de un valor. JSON sirve para otros programas; CBOR conserva lo que JSON pierde o deforma: un `Map` con claves `Int`, los bits exactos de un `Float` (infinitos incluidos), `nil` como valor propio, `Bytes` y un enum como un arreglo simple. También es más pequeño. Usos típicos son un caché en disco y los mensajes entre programas de Agentica. Leer los bytes de vuelta, `Term.decode`, llega más adelante: por ahora `Term.encode` da los bytes, y otro programa los lee como CBOR.

```signature
Term.encode(value: T) -> Result[Bytes]
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
end
```

```text
a26468697473a2020501076573636f7265fb3ff8000000000000
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

Una estructura o un enum genérico se escribe por sus campos con los argumentos de tipo puestos. Todo otro tipo es `CHECK-NOT-ENCODABLE`, con el span en el argumento: una función, un `Set`, un `Result`, un `Void`, `JSON.Value` y `JSON.Field`, las fechas y horas de `Time`, un `Range` y todos los handles (`File.Handle`, `Process`, `TCP.Socket`, una `Task`, un `Channel` y los demás), a cualquier profundidad. El argumento tiene un tipo concreto: una variable de tipo de una función genérica también se rechaza. Un campo privado de una estructura de otro módulo es `CHECK-PRIVATE-FIELD`, como en `JSON.encode`.

## Mismo valor, mismos bytes {#same-value-same-bytes}

La forma es determinista (RFC 8949 sección 4.2): la cabecera más corta de cada elemento, y longitudes que siempre se conocen. Dos reglas de esa sección no se siguen a propósito: las claves de un mapa conservan el orden de inserción, porque un `Map` de Agentica está ordenado y el orden es parte de su valor, y los flotantes siempre ocupan su ancho completo, así que un `Float` nunca vuelve como un `Int` y sus bits son exactos.

## Límites {#limits}

`Term.encode` es para datos, no para entradas sin límite. Devuelve un `error` con la ruta del primer valor que cruza un límite, y deja de escribir ahí; nunca se detiene con un halt por ellos.

- **Profundidad:** como máximo 10,000 niveles. Una estructura, una `List`, un `Map` y un enum son un nivel cada uno (un enum es un nivel aunque sean dos arreglos CBOR); un `Optional` no añade ninguno.
- **Valores:** como máximo 4,000,000 valores en total. La clave de un `Map` cuenta como un valor y el nombre de un campo no.
- **Tamaño:** como máximo 64 MiB de salida.

El mensaje es `ruta: motivo`, con la ruta de los errores de `JSON.decode`: la raíz es `$`, un campo es `by_name`, un índice `[3]`, una clave `Int` `[3]`, una clave `String` `["k"]`, y un payload de un enum `values[0]`:

```text
items[0].values[0][3999996]: more than 4000000 values
$: larger than 67108864 bytes
```

La clase del error es `term.encode` (consulta los [errores](/library/errors/error/)). Para más datos, codifícalos en trozos, cada uno como su propio valor.
