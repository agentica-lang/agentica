## 16. Binary serialization (CBOR)

Issue #994, on demand: it starts when a real program needs it (a disk cache, or
messages between Agentica processes). The counterpart of Erlang's
`term_to_binary` and `binary_to_term`: a typed binary form of Agentica values,
in CBOR ([RFC 8949](https://www.rfc-editor.org/rfc/rfc8949)). Issue #748
mentions `Term` only for `JsonField` (a `Term` writes `JsonField` as a plain
generic enum).

### 16.1 Motivation

JSON covers interop with other programs. A binary form keeps what JSON loses or
bends: `Map[Int, V]` (JSON object keys are always text), exact `Float` bits
(infinities included), `nil` as its own value, and enums as a plain array. It is
also smaller and faster. Uses: a disk cache, messages between Agentica
processes over `Process.spawn` pipes, and a snapshot of an `ATS` table through
`ATS.to_map`.

### 16.2 API

```agentica
struct Entry
  hits: Map[Int, Int]
  score: Float
end

def round_trip(entry: Entry) -> Result[Entry]
  data = try Term.encode(entry)      # Bytes
  return Term.decode(data, Entry)
end
```

```text
Term.encode(value: T) -> Result[Bytes]
Term.decode(data: Bytes, type: T) -> Result[T]
```

- `encode` returns a `Result` because it can fail on data the checker cannot
  see: a value nested too deep, with too many items, or with bytes past the 64
  MiB limit (16.5). It never halts on these.
- The second argument of `decode` is a static type argument, as in
  `JSON.decode(text, User)`. The direct target is a bare named non-generic
  struct or enum (a top-level `List[Int]`, `Int` or `nil` is wrapped in a
  struct on both sides); types inside it follow 16.3 in full, generic instances
  included.
- There is never an untyped decode. Erlang's `binary_to_term` is a known attack
  vector (atoms, functions, huge terms). Here the target type decides what is
  accepted, and nothing outside it is ever built.
- No method form (`value.to_cbor`): JSON has none either, and structs and enums
  have no methods.
- `Term` becomes a reserved type and module name (`CHECK-REDEFINED-NAME`;
  breaking, say so in the changelog).

### 16.3 What can be serialized

The same data rule as printing: no `Fn`, `Task`, `Table` or resource handle
(`FileHandle`, `Process`, `Socket` and the rest), at any depth. `Json`, `Result`
and `Void` are rejected at any depth too (`Json` has its own text form;
`Result` is for error flow, not stored data: use a user enum).

- The type check is a new walk, not the JSON one: it substitutes the type
  arguments of a generic instance into field and payload types, and cuts
  recursion with a `seen` set keyed on the substituted type, so `Tree[Int]`
  stops when it meets `Tree[Int]` again while `Box[Int]` and `Box[String]` are
  checked apart.
- A type that fails the rule is `CHECK-NOT-ENCODABLE` (`encode`) or
  `CHECK-NOT-DECODABLE` (`decode` target), with the span on the argument. The
  argument of `encode` has a concrete static type, as `JSON.encode` requires.
- Unlike JSON, `Map` keys may be `Int` (key types stay `Int` or `String`). `Nil`
  is allowed.
- A generic instance as the direct `decode` target stays out (`Option[Int]` in
  argument position reads as indexing): wrap it in a struct.

### 16.4 Format mapping

| Agentica | CBOR |
|---|---|
| `Int` | major type 0 (`n >= 0`) or 1 (`n < 0`) |
| `Float` | always a 64-bit float (major type 7, additional info 27) |
| `String` | text string (major type 3) |
| `Bool` | simple values `false` (0xF4) and `true` (0xF5) |
| `nil` | simple value `null` (0xF6) |
| `List[T]` | array (major type 4) |
| `Map[K, V]` | map (major type 5), in insertion order |
| struct | map keyed by field name, in declaration order |
| enum | 2-element array `[tag, [values...]]` |
| `Bytes` | byte string (major type 2) |

- **Int:** decode rejects values outside signed 64-bit; bignum tags are
  rejected like any tag.
- **Float:** always 8 bytes, so the bits are exact and a `Float` never comes
  back as an `Int`. Infinities and `-0.0` keep their IEEE form; every NaN is
  written as the quiet NaN `0x7FF8000000000000`.
- **String:** invalid UTF-8 is rejected on decode, with the rule of the `.agcb`
  loader (`docs/vm/08-loader-and-cli.md` §8).
- **Map:** encode keeps insertion order and decode the order of the bytes, so a
  round trip keeps the order (`JSON.decode` sorts keys). Duplicate keys are
  rejected on decode.
- **Struct:** a map from field name to value, not an array in field order: an
  array is smaller but any change of fields breaks old data, silently when two
  fields have the same type. Decode accepts keys in any order, rejects
  duplicates, and ignores extra keys. Removing or reordering fields is safe.
  **Adding a field breaks old data**: a default only fills a constructor, not a
  decode, so a missing field is an error.
- **Enum:** `[tag, values]`: `tag` is the variant name without the enum name,
  `values` an array of the payloads in declaration order, always present
  (`["Empty", []]`). Same order as the JSON form of enums. An unknown tag, a
  wrong length or a malformed outer array is an error.
- **Deterministic encoding** (RFC 8949 §4.2): shortest heads and definite
  lengths only. Two rules of §4.2.1 are not followed, on purpose: map keys keep
  insertion order (an Agentica `Map` is ordered, so the order is part of the
  value), and floats always take 8 bytes.
- **Decode accepts only what encode writes**, except that struct keys may come
  in any order and extra struct keys are ignored (still checked as well formed).
  It rejects indefinite lengths, every tag, other simple values, a non-shortest
  head, non-8-byte floats, other NaNs and trailing bytes. Reading CBOR from
  other programs is not a goal; JSON covers interop.
- `decode(encode(v))` gives `v`. `encode(decode(b))` gives back `b` only when
  `b` is canonical.

### 16.5 Untrusted input

`Term.decode` treats its bytes like the `.agcb` loader treats a file: they may
come from another process or a file anyone could write.

- **Depth:** at most 10,000 levels, counting Agentica value nesting, not CBOR
  nesting (an enum is one level though it is two CBOR arrays). Encode and decode
  count the same way. The VM walks with an explicit stack, never C recursion.
- **Lengths before allocation:** every length is checked against the bytes left
  before anything is allocated (each item takes at least one byte), with
  overflow-safe sums.
- **Item cap:** one input byte can become a value of some tens of bytes, so
  decode counts the values it reads. Past `TERM_MAX_ITEMS` = 4,000,000 it stops
  with `$: too many items`; encode counts the same way. For more data, encode
  chunks as separate values.
- **Total size:** input above 64 MiB is an error before any reading. Ignored
  struct values count toward size, depth and item limits like any other.
- **Errors are Results**, never runtime diagnostics, with the path style of
  `JSON.decode`: `<path>: <reason>`, lowercase, no final period; the root is `$`
  (`$: trailing bytes after the value`, `users[2].name: expected String`,
  `shapes[1]: unknown tag "Triangle"`). An `Int` map key is written in decimal
  (`hits[3]`), a `String` key in double quotes with JSON escaping.
- **Encode keeps the same limits** (depth, item cap, 64 MiB) and returns an
  error with the path of the first value that crosses the limit; it stops
  writing as soon as a limit is passed.

### 16.6 Versioning and framing

No version prefix and no self-describing tag: the type is the schema. Put a
`version: Int` field in the top struct from the first release. To add a field,
keep the old type (`CacheV1`) next to the new one (`CacheV2`): decode with
`CacheV2`, on error decode again with `CacheV1` and convert; the retry works the
other way too, because extra keys are ignored.

Decode rejects trailing bytes, so a stream needs framing: a 4-byte big-endian
length (`std/binary`), then the bytes in slices of at most 1 MiB (the limit of
`Process.send_bytes` and `TCP.send_bytes`). The receiver rejects a length above
its limit (at most 64 MiB) before reading the body. A helper module could hold
the loops; it is not part of this plan.

The backend is an in-house C codec in `vm/`, with no new dependency.

### 16.7 Not planned

- **Functions and handles:** a `Fn` may capture handles, and a handle is only
  valid inside the run that made it.
- **Untyped decode:** the `binary_to_term` attack surface.
- **Erlang distribution** (transparent messages between nodes): processes talk
  through pipes or TCP with explicit `Term.encode` and `Term.decode`, so
  failures stay visible as Results.
