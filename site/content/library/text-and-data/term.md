---
title: Term (CBOR)
weight: 15
description: Write an Agentica value as CBOR and read it back into a struct or enum, a compact binary form that keeps Int keys, exact Float bits, nil, Bytes and enums.
---

`Term.encode` writes a value as [CBOR](https://www.rfc-editor.org/rfc/rfc8949) bytes, the binary form of a value. JSON is for other programs; CBOR keeps what JSON loses or bends: a `Map` with `Int` keys, the exact bits of a `Float` (infinities included), `nil` as its own value, `Bytes`, and an enum as a plain array. It is also smaller. Typical uses are a disk cache and messages between Agentica programs. `Term.decode` reads the bytes back into the type you name: the type is the schema, so nothing outside it is ever built.

```signature
Term.encode(value: T) -> Result[Bytes]
Term.decode(data: Bytes, type: T) -> Result[T]
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
  puts(Term.decode(bytes, Entry).unwrap!.hits)
end
```

```output
a26468697473a2020501076573636f7265fb3ff8000000000000
{2: 5, 1: 7}
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

`JSON.Field[T]` is a plain enum here, `[tag, [values...]]` with the tags `Absent`, `Null` and `Value`, and it can sit anywhere a type can. A generic struct or enum is written by its fields with the type arguments in place. Every other type is `CHECK-NOT-ENCODABLE`, with the span on the argument: a function, a `Set`, a `Result`, a `Void`, `JSON.Value`, the dates and times of `Time`, a `Range`, and every handle (`File.Handle`, `Process`, `TCP.Socket`, a `Task`, a `Channel` and the rest), at any depth. The argument has a concrete type: a type variable of a generic function is refused too. A private field of a struct of another module is `CHECK-PRIVATE-FIELD`, as in `JSON.encode`.

## Same value, same bytes

The form is deterministic (RFC 8949 section 4.2): the shortest head of each item, and lengths that are always known. Two rules of that section are not followed on purpose: map keys keep the insertion order, because an Agentica `Map` is ordered and the order is part of its value, and floats always take their full width, so a `Float` never comes back as an `Int` and its bits are exact.

## Limits

`Term.encode` is for data, not for unbounded input. It returns an `error` with the path of the first value that crosses a limit, and stops writing there; it never halts on them.

- **Depth:** at most 10,000 levels. A struct, a `List`, a `Map` and an enum are one level each (an enum is one level though it is two CBOR arrays); an `Optional` adds none.
- **Values:** at most 4,000,000 values in all. A `Map` key counts as a value and a field name does not.
- **Size:** at most 64 MiB of output.

The message is `path: reason`, with the path of `JSON.decode` errors: the root is `$`, a field is `by_name`, an index `[3]`, an `Int` key `[3]`, a `String` key `["k"]` (cut at 64 bytes, with `...` after the cut), and a payload of an enum `values[0]`:

```text
items[0].values[0][3999996]: more than 4000000 values
$: larger than 67108864 bytes
```

The kind of the error is `term.encode` (see [errors](/library/errors/error/)). For more data, encode it in chunks, each as its own value.

## Term.decode

`Term.decode(data, Name)` reads the bytes into the struct or enum `Name` and returns `ok(value)`, or an `error` with the path of the first bad value. The second argument is a type name, as in `JSON.decode(text, User)`: a bare struct or enum, so a `List`, a `Map` or an instance of a generic struct such as `Box[Int]` is not a target (`CHECK-TYPE-MISMATCH`); put it in a field of a struct. Everything inside the target follows the table above, and a generic struct instance works as a field.

`Term.encode` accepts more than `Term.decode` can target, as `JSON.encode` does against `JSON.decode`: it writes a `List`, a `Map` or an instance of a generic enum as the whole value, and a struct with a generic enum inside. `Term.decode` takes only a bare struct or enum as the target, and a generic enum anywhere inside it is `CHECK-NOT-DECODABLE`, with the span on the type name. To read such data back, use a plain enum or a struct, and put a `List` or a `Map` in a field.

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

```output
Shape.Circle(1.5)
```

There is never a decode without a type: the bytes cannot name a type to build, and a function, a handle or an unbounded structure cannot be asked for.

- **Same value back:** `Term.decode(Term.encode(v), T)` gives `v` for every type that `Term.decode` can target. `Term.encode(Term.decode(bytes, T))` gives `bytes` back only when `bytes` is what `Term.encode` writes.
- **Only what `Term.encode` writes:** a head longer than needed, an indefinite length, a tag, a half float, a float with the width of another type (`Float` reads 8 bytes, `Float32` 4), a NaN with a payload, text that is not UTF-8, a `Map` key twice, and bytes after the value are errors. An `Int` outside 64 bits is an error, and so is a value outside the range of an `Int8` to `UInt32`.
- **Structs:** the keys may come in any order and a key that names no field is read and ignored (with the same checks, and the same limits). A key named twice (a field or not) in the struct itself, and a field that is missing, are errors (the keys of a map inside an ignored value are not checked for repeats): a default value of a field only fills a constructor, so **adding a field breaks old data**. Removing or reordering fields is safe.
- **Enums:** an unknown tag, a payload list of another length, and an outer array that is not of two items are errors.

The limits are those of `Term.encode`: 10,000 levels, 4,000,000 values and 64 MiB, and a value past one returns an error as it does there. The input is read with the same care as a file of bytecode: every length is checked against the bytes left before anything is built, so a few bytes cannot ask for a large amount of memory. The kind of the error is `term.decode`, and the path has the same form: `users[2].name: expected String`, `shapes[1]: unknown tag "Triangle"`, `$: trailing bytes after the value`, `x: expected signed 64-bit Int`. Where the type is an `Optional`, the expected type is followed by `or nil`.

## Versioning and framing

The bytes carry no version and no type: the type is the schema. Put a `version: Int` field in the top struct from the first release. To add a field, keep the old struct (`CacheV1`) next to the new one (`CacheV2`): decode with `CacheV2`, and on error decode again with `CacheV1` and convert.

`Term.decode` rejects bytes after the value, so a stream needs framing: a 4-byte big-endian length (`std/binary`), then the bytes in slices of at most 1 MiB (the limit of `Process.send_bytes` and `TCP.send_bytes`). The receiver rejects a length above its limit before it reads the body.

## Not supported

A `Fn` and a handle (a handle is only valid inside the run that made it), a decode without a type, and the transparent messages of Erlang's distribution: programs talk through pipes or TCP with explicit `Term.encode` and `Term.decode`, so a failure is a `Result` that the program sees.
