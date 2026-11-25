---
title: Term (CBOR)
weight: 15
description: Write an Agentica value as CBOR, a compact binary form that keeps Int keys, exact Float bits, nil, Bytes and enums.
---

`Term.encode` writes a value as [CBOR](https://www.rfc-editor.org/rfc/rfc8949) bytes, the binary form of a value. JSON is for other programs; CBOR keeps what JSON loses or bends: a `Map` with `Int` keys, the exact bits of a `Float` (infinities included), `nil` as its own value, `Bytes`, and an enum as a plain array. It is also smaller. Typical uses are a disk cache and messages between Agentica programs. Reading the bytes back, `Term.decode`, is a later addition: for now `Term.encode` gives the bytes, and another program reads them as CBOR.

```signature
Term.encode(value: T) -> Result[Bytes]
```

`Term` is a reserved type and module name, so a struct, an enum or an alias cannot take it (`CHECK-REDEFINED-NAME`).

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

The bytes are a map of two entries: the key `"hits"` with a map from `2` to `5` and `1` to `7` (in the order they were put), and the key `"score"` with an 8-byte float.

## What it writes

| Agentica | CBOR |
|---|---|
| `Int`, `Int8` to `Int32`, `UInt8` to `UInt32` | an integer (major type 0 or 1) in the fewest bytes |
| `UInt64` | an integer from `0` to `18446744073709551615` |
| `Float` | always a 64-bit float. Every NaN is written as the quiet NaN `0x7FF8000000000000`; `-0.0` and the infinities keep their bits |
| `Float32` | always a 32-bit float; every NaN is `0x7FC00000` |
| `String` | a text string (UTF-8) |
| `Bytes` | a byte string |
| `Bool`, `nil` | `false`, `true` and `null` |
| `List[T]` | an array |
| `Map[K, V]` | a map in insertion order. `K` is `Int` or `String`; a sized integer or a `UInt64` as a key is `CHECK-NOT-ENCODABLE` |
| struct | a map from the field name to the value, in the order of the declaration |
| enum | the array `[tag, [values...]]`: `tag` is the variant name without the enum name, and `values` has the payloads, `["Empty", []]` for a variant with none |
| `Optional[T]` | `null` for `none`, the value for `some`. `Optional[Nil]` and an `Optional` of an `Optional` are refused: they could not be told apart |

A generic struct or enum is written by its fields with the type arguments in place. Every other type is `CHECK-NOT-ENCODABLE`, with the span on the argument: a function, a `Set`, a `Result`, a `Void`, `JSON.Value` and `JSON.Field`, the dates and times of `Time`, a `Range`, and every handle (`File.Handle`, `Process`, `TCP.Socket`, a `Task`, a `Channel` and the rest), at any depth. The argument has a concrete type: a type variable of a generic function is refused too. A private field of a struct of another module is `CHECK-PRIVATE-FIELD`, as in `JSON.encode`.

## Same value, same bytes

The form is deterministic (RFC 8949 section 4.2): the shortest head of each item, and lengths that are always known. Two rules of that section are not followed on purpose: map keys keep the insertion order, because an Agentica `Map` is ordered and the order is part of its value, and floats always take their full width, so a `Float` never comes back as an `Int` and its bits are exact.

## Limits

`Term.encode` is for data, not for unbounded input. It returns an `error` with the path of the first value that crosses a limit, and stops writing there; it never halts on them.

- **Depth:** at most 10,000 levels. A struct, a `List`, a `Map` and an enum are one level each (an enum is one level though it is two CBOR arrays); an `Optional` adds none.
- **Values:** at most 4,000,000 values in all. A `Map` key counts as a value and a field name does not.
- **Size:** at most 64 MiB of output.

The message is `path: reason`, with the path of `JSON.decode` errors: the root is `$`, a field is `by_name`, an index `[3]`, an `Int` key `[3]`, a `String` key `["k"]`, and a payload of an enum `values[0]`:

```text
items[0].values[0][3999996]: more than 4000000 values
$: larger than 67108864 bytes
```

The kind of the error is `term.encode` (see [errors](/library/errors/error/)). For more data, encode it in chunks, each as its own value.
