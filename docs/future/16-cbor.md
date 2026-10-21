## 16. Binary serialization (CBOR)

The counterpart of Erlang's `term_to_binary` and `binary_to_term`: a typed
binary form of Agentica values, in CBOR ([RFC
8949](https://www.rfc-editor.org/rfc/rfc8949)). It lands only when a real
program needs it (roadmap Phase 11).

### 16.1 Motivation

JSON covers interop with other programs. A binary form keeps what JSON loses or
bends:

- `Map[Int, V]`: JSON object keys are always text, so `JSON.encode` rejects Int
  keys today.
- Exact `Float` bits: JSON goes through decimal text and cannot write
  infinities.
- `nil` as its own value, and enums as a plain array instead of an object
  convention.

It is also smaller and faster to read and write. Uses: a disk cache, messages
between Agentica processes (over `Process.spawn` pipes), and later a snapshot of
a shared table (§13) through `Table.to_map`.

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

def main() -> Void
  IO.inspect(round_trip(Entry(hits: {1: 10, 2: 20}, score: 0.5)))
end
```

```text
Term.encode(value: T) -> Result[Bytes]
Term.decode(data: Bytes, type: T) -> Result[T]
```

- `encode` returns a `Result` because it can fail on data the checker cannot
  see: a value nested too deep, with too many items, or with bytes past the 64
  MiB limit (16.5). It never halts on these.
- The second argument of `decode` is a static type argument, not a value, as in
  `JSON.decode(text, User)`: a type name written in argument position. It is
  checked at compile time and has no run-time value.
- Allowed types are the same for both functions: the rule of 16.3. The one extra
  limit is syntax: the direct `decode` target is written as a bare name, so it
  is a named non-generic struct or a named non-generic enum. Types inside it
  (fields, payloads, list elements, map keys and values) follow 16.3 in full,
  generic instances included.
- There is never an untyped decode. Erlang's `binary_to_term` is a known attack
  vector: it can create atoms until the atom table is full, build functions, and
  allocate huge terms. Here the target type decides what is accepted, and
  nothing outside it is ever built.
- No method form (`value.to_cbor`). JSON has no `.to_json` either, and structs
  and enums have no methods. One spelling is easier for agents.
- The module is named for what it stores, not for the format. `Term` becomes a
  reserved type and module name: a user `struct Term`, `enum Term` or
  `import ... as Term` is `CHECK-REDEFINED-NAME`. This is a breaking change; say
  so in the changelog.

### 16.3 What can be serialized

The same data rule as printing: no `Fn`, `Task`, `Table` or resource handle
(`FileHandle`, `Process`, `Socket` and the rest), at any depth.

- The check is a new walk in the checker. `data-type?` (the deep walk that §13
  uses for table values) only gives the base list of allowed and denied leaf
  types; it cannot be reused as is, for two reasons. It accepts `Json`, `Result`
  and type variables, which Term must reject. And its `seen` key is
  `(kind . name)`, without the type arguments, so once it has walked `Box[Int]`
  it would skip `Box[String]` inside it as already seen. The new walk looks
  through list elements, `Map` keys and values, struct fields and enum payloads,
  and for a generic instance it first substitutes the instance's type arguments
  into the field and payload types, then recurses into the result.
- Recursion is cut off with a `seen` set keyed on the substituted type: its kind
  (struct or enum), its name and its type arguments. A recursive type stops
  there: for `enum Tree[T]` with a payload `Node(List[Tree[T]])`, the walk of
  `Tree[Int]` stops when it meets `Tree[Int]` again, while `Box[Int]` and
  `Box[String]` are still checked apart.
- On top of the base list, `Json`, `Result`, `Void` and `Fn` are rejected at any
  depth of the type, not only at the top: `Box[Json]`, a field
  `items: List[Result[Int]]` and a payload `Map[String, Fn[Int, Int]]` all fail.
  `Json` has its own text form (`JSON.encode` it to a `String` first). `Result`
  is for error flow, not stored data (use a user enum).
- **Concrete types only:** the argument of `encode` must have a concrete static
  type, with every type parameter known, as `JSON.encode` requires today (its
  `encodable-type?` rejects a type variable). The checker already gives this at
  every call site: there are no user generic functions, a constructor whose type
  parameters cannot be inferred is `CHECK-ENUM-TYPE-INFERENCE`, and an empty
  `[]` or `{}` with no expected type is `CHECK-EMPTY-LIST-TYPE` or
  `CHECK-EMPTY-MAP-TYPE`. If a type variable ever reaches `Term.encode` or a
  `decode` target (for example once generic functions exist), it is
  `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`. Only type variables left after
  substitution are rejected: the `T` in the declaration of `Box[T]` is fine when
  the instance is `Box[Int]`. Encode never falls back to the run-time shape
  of the value.
- Codes: `Term.encode` on a type that fails the rule is `CHECK-NOT-ENCODABLE`; a
  `Term.decode` target that fails it is `CHECK-NOT-DECODABLE`. The span is on
  the argument, as for JSON.
- Unlike JSON, `Map` keys may be `Int`. Key types stay `Int` or `String`
  (`CHECK-MAP-KEY-TYPE`), so nothing new is needed there.
- `Nil` is allowed, as a field type or a payload.
- **Generic instances:** both functions take generic instances (`Option[Int]`,
  `Box[String]`) inside the type, checked after substitution (see the walk
  above). JSON decode rejects them only because its schema keys `$defs` by the
  bare type name, so `Box[Int]` and `Box[String]` would collide (§15.3). CBOR
  has no schema: the decoder walks the substituted type, which the checker knows
  in full. A generic instance as the direct `decode` target stays out:
  `Term.decode(data, Option[Int])` needs type arguments in expression position
  (`Option[Int]` reads as indexing), and a bare `Option` is
  `CHECK-UNKNOWN-TYPE`, as today. Wrap it in a struct.

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

- **Int:** decode rejects values outside signed 64-bit (`major 0` above
  `2^63 - 1`, `major 1` below `-2^63`). Bignum tags (2, 3) are rejected like any
  tag.
- **Float:** always 8 bytes, so the bits are exact and a `Float` never comes
  back as an `Int`. Infinities and NaN can occur in Agentica values: a Float
  overflow gives infinity, and `inf - inf` gives NaN (`grammar.md` says that a
  NaN is not equal to itself). They are written as IEEE 754 values, and `-0.0`
  keeps its sign. Every NaN is written as the quiet NaN `0x7FF8000000000000`, so
  the same bytes come out whatever NaN payload the host makes. Decode reads a
  `Float` only from the 8-byte form; half and single floats are rejected.
- **String:** invalid UTF-8 (overlong forms, surrogates, code points above
  U+10FFFF, truncated sequences) is rejected on decode, with the same rule as
  the `.agcb` loader (`docs/vm/08-loader-and-cli.md` §8).
- **Map:** encode keeps insertion order and decode keeps the order of the bytes,
  so a round trip keeps the order (`JSON.decode` sorts keys instead). Duplicate
  keys are rejected on decode. Keys must match `K`: text strings for `String`,
  major 0/1 for `Int`.
- **Struct:** a map from field name (text string) to value, not an array in
  field order. An array is smaller, but any change of fields breaks old data,
  and when two fields have the same type it breaks it silently: the values swap.
  Decode accepts the keys in any order. Duplicate keys are rejected, as for
  `Map`, whether or not the field is known: two equal keys that the struct does
  not have are an error too. Inside an ignored value, maps are not checked for
  duplicate keys; they are only read with the size, depth and item checks
  (16.5). What a change of the struct does to old data:
  - **Removing or reordering fields is safe:** fields are keyed by name, and
    extra keys are ignored on decode, as in `JSON.decode`.
  - **Adding a field breaks old data:** there are no field defaults, and a
    missing field is an error. Old bytes do not have the new key, so they no
    longer decode with the new type. 16.6 says how to handle it.
- **Enum:** a CBOR array of exactly 2 items, `[tag, values]`:
  - `tag` is the variant name without the enum name, as a text string:
    `"Circle"`, not `"Shape.Circle"`.
  - `values` is a CBOR array that holds the payloads in declaration order, each
    in the form of its own type. A nullary variant has an empty array:
    `["Empty", []]`. The array is always there, also when it is empty.
  - For `Circle(2.0)` of `enum Shape`: `["Circle", [2.0]]`, which is the bytes
    `82 66 "Circle" 81 FB 4000000000000000`.
  - Decode reads the tag, finds the variant in the target enum (the static type
    at that point), and then reads exactly as many values as that variant has
    payloads, each against its payload type. An unknown tag, a values array of
    the wrong length, a missing values array, or an outer array that does not
    have exactly 2 items is an error.
  - Error paths for enum payloads are `<enum path>.values[i]` (for example
    `shapes[0].values[1]`), so they read the same as the JSON form.
  - This is the same tag and values order as the JSON form of enums
    (`{"tag": ..., "values": [...]}`, §15.4), written as an array instead of an
    object. The two must not drift apart: if §15.4 changes its tag rule, this
    section changes with it.
- **Deterministic encoding** (RFC 8949 §4.2): the shortest form of every integer
  and length head, and definite lengths only, so the same value, built the same
  way, gives the same bytes. "Built the same way" matters for maps, whose
  insertion order is kept: `{1: 10, 2: 20}` and `{2: 20, 1: 10}` hold the same
  entries but give different bytes. `0.0` and `-0.0` encode differently too,
  since the sign bit is kept. Two rules of §4.2.1 are not followed, on purpose:
  map keys keep insertion order (an Agentica `Map` is ordered, so the order is
  part of the value), and floats always take 8 bytes (so `Float` bits are
  exact).
- **Decode accepts only what encode writes**, with one freedom: struct keys may
  come in any order, and extra struct keys are ignored. It accepts only shortest
  heads, definite lengths, 8-byte floats, the one NaN above, and no tags at all.
  It rejects indefinite lengths, every tag, other simple values (`undefined` and
  the rest), a non-shortest head, and trailing bytes after the value. An ignored
  struct value is still read and checked as well formed (heads, lengths, no
  tags, valid UTF-8, the depth limit), only its type and duplicate map keys are
  not checked. Reading CBOR from other programs is not a goal; JSON covers
  interop.
- **Round trips:** `decode(encode(v))` gives `v`, compared by bytes or by
  printed output (`==` does not hold for a NaN). Every NaN comes back as the one
  canonical NaN above, so its bits are not kept; all other `Float` bits are
  exact. Whatever `encode` returns as `ok`, `decode` reads with the same type,
  with no extra condition, because encode keeps the same depth, item and size
  limits (16.5). In the other direction, `encode(decode(b))` gives back exactly
  `b` only when `b` is canonical, that is, bytes that `Term.encode` wrote. For
  any other input that decode accepts, the bytes are the same except for
  reordered or ignored struct keys: the struct keys come back in declaration
  order and the ignored keys are gone.

### 16.5 Untrusted input

`Term.decode` treats its bytes like the `.agcb` loader treats a file
(`docs/vm/08-loader-and-cli.md` §8): they may come from another process or a
file anyone could write.

- **Depth:** at most 10,000 levels, the same number as the call depth limit.
  Depth counts Agentica value nesting, not CBOR nesting:
  - The top value is at depth 1. A value inside a `List`, `Map`, struct or enum
    (an element, a key or value, a field, a payload) is one level deeper than
    that container. No value may be deeper than 10,000.
  - An enum is one level, though it is two CBOR arrays: the outer
    `[tag, values]` array and its inner `values` array together count once. For
    `W(v: Some(Some(1)))` the `1` is at depth 4 (the struct is 1, each `Some`
    one more); counted by CBOR arrays and maps it would be at depth 6.
  - Encode and decode count the same way, so whatever `encode` writes, `decode`
    reads within the depth limit. Decode knows where an enum starts from the
    target type.
  - An ignored struct value (16.4) has no Agentica type, so there each CBOR
    array or map counts as one level, from the depth of the struct.
  - Depth is checked when a container is entered, before any of its items are
    read. A value at depth 10,000 is accepted; one at depth 10,001 is an error.
  - The VM walks with an explicit stack, never with C recursion
    (`docs/vm/05-values-execution-builtins.md` §7.3).
- **Lengths before allocation:** every length is checked against the bytes left
  before anything is allocated. Each item takes at least one byte, so an array
  of `n` items needs at least `n` bytes left, a map of `n` entries at least
  `2n`, and a byte or text string exactly its length. All sums use `uint64_t`
  and the form `size > limit - total`.
- **Item cap:** this check alone does not keep memory small. One input byte (an
  empty array, `0xF6`, a small Int) can become a value that takes some tens of
  bytes in memory, so 64 MiB of input could build a few GiB. So decode also
  counts the values it reads: every Agentica value is one item. That is the top
  value (for example the top struct), each struct field value, each list
  element, each map key and each map value, each enum value (its outer
  `[tag, values]` array and its `values` array count as one item together) and
  each payload value. Inside an ignored struct value, which has no Agentica
  type, every CBOR item counts as one. When the count passes `TERM_MAX_ITEMS` =
  4,000,000, decode stops with `$: too many items`. Encode counts the
  same way (below). So `Wrap(items: xs)` with
  `xs: List[Int]` of `n` elements has 2 + `n` items (the struct, the field value
  `xs`, and the `n` elements): the largest list that fits is 3,999,998 elements,
  and one more is `$: too many items`. For more data, split it into chunks and
  encode each chunk as its own value. In the worst case that is about 4,000,000
  times the size of the largest small value (some hundreds of MiB), plus strings
  and byte strings, which are bounded by the input.
- **Total size:** input above 64 MiB is an error before any reading.
- **Ignored values count too:** an ignored struct value (16.4) is read in full,
  so its bytes count toward the size and length checks, its nesting toward the
  depth limit, and its items toward the item cap, like any other value.
- **Errors are Results:** every problem returns `error(...)`, never a runtime
  diagnostic, with the path style of `JSON.decode`: `<path>: <reason>`,
  lowercase, with no final period. The root is `$`; below it the path starts
  with the first field, index or key, with no `$.` prefix, exactly as
  `JSON.decode` writes it (`shapes[0].values[1]`, `hits[3]`,
  `users["ana"].age`). Examples: `$: trailing bytes after the value`,
  `users[2].name: expected String`, `items: length is larger than the input`,
  `$: depth limit exceeded`, `$: too many items`,
  `$: indefinite length is not allowed`, `$: tags are not allowed`,
  `score: expected a 64-bit Float`, `shapes[1]: unknown tag "Triangle"`,
  `shapes[0].values: expected 2 values, found 1`.
- **Map keys in paths:** an `Int` key is written in decimal (`hits[3]`). A
  `String` key is written in double quotes with JSON string escaping: `\"` and
  `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, any other code point below U+0020 as
  `\u00XX` with lowercase hex, and every other character as is, in UTF-8
  (`users["a\"b"]`). `JSON.decode` writes keys the same way.
- **Paths are built only on error:** while walking, the walk keeps a stack
  of path segments (a field name, an index or a key) and pushes and pops one per
  level. The path text is joined from the stack only when an error happens,
  never rebuilt at every level, so the cost stays linear in the input.
- **Depth and item-cap errors use the root path:** `$: depth limit exceeded` and
  `$: too many items`, in both directions, with no deeper path. All other errors
  keep the full path.
- **Encode keeps the same limits and returns errors too:** a value deeper than
  the depth limit, with more than `TERM_MAX_ITEMS` values (counted as decode
  counts them), or whose bytes would pass 64 MiB, returns `error(...)`. The
  depth error is `$: depth limit exceeded` and the item error is `$: too many
  items`, as on decode; the size error has the path of the first value that
  crosses the limit (`cache["big"]: encoded size is larger than 64 MiB`). It
  never halts: unlike a non-finite Float in `JSON.encode`
  (`RUNTIME-JSON-ENCODE`), these limits depend on the size of the data, which a
  program cannot easily check before the call. Encode stops writing as soon as a
  limit is passed, so it never builds more than 64 MiB. Only a named struct or
  enum can be the `decode` target (16.2), so a top-level value of another type
  (`List[Int]`, `Int`, `nil`) must be wrapped in a struct on both sides: encode
  `Wrap(items: xs)`, decode with `Wrap`.

### 16.6 Versioning

No version prefix and no self-describing tag (55799). The type is the schema. A
prefix would cost bytes in every message and would still not say which type to
decode into. If the mapping ever changes, that is a new function, not a flag in
the data.

- **Put a `version: Int` field in the top struct from the first release.** Data
  written later can then say which shape it has.
- **To add a field** (which breaks old data, 16.4): keep the old type, say
  `CacheV1`, next to the new `CacheV2`. Decode with `CacheV2`; on error, decode
  again with `CacheV1` and convert the result to `CacheV2`. The retry works the
  other way too, because extra keys are ignored: `CacheV1` reads `CacheV2`
  bytes. Check `version` after the decode to tell the shapes apart when both
  decode.

### 16.7 Backends

- **VM:** an in-house C codec in `vm/`, with no new dependency. It needs `Bytes`
  on the VM. CBOR is small: one head byte, then 0, 1, 2, 4 or 8 bytes of
  argument.
- **Tests:** the RFC 8949 Appendix A vectors that fit the mapping, as fixed
  bytes in `tests/fixtures/` (they come from the RFC, not from our encoder, so
  they are the independent counterpart); round trips (`decode(encode(v))` gives
  `v`; `encode(decode(b))` gives `b` for canonical `b`, the canonical bytes for
  reordered or extra struct keys); the depth boundary (an enum nested 10,000
  levels round trips, one more level is `$: depth limit exceeded`); the item
  cap boundary (`Wrap(items: xs)` with 3,999,998 elements round trips, with
  3,999,999 it is `$: too many items`, on encode and on decode with the input
  built by hand); encode errors with their paths; and hostile input (truncation
  at every byte, lengths larger than the input, depth one above the limit,
  4,000,001 one-byte items also inside an ignored struct value, duplicate map
  and struct keys also when the struct does not have the key, tags, indefinite
  lengths, non-shortest heads, invalid UTF-8, Ints outside int64, trailing
  bytes). The VM loader fuzzer (`make vm-fuzz`) gets a decode target too.
- **Framing:** decode rejects trailing bytes, so a stream of messages needs
  framing. A message can be up to 64 MiB, but `Process.send_bytes` and
  `TCP.send_bytes` take at most 1 MiB per call, and `Process.read_bytes` and
  `TCP.recv_bytes` take a count of at most 1,048,576. So:
  - the sender writes a fixed 4-byte big-endian length, then the bytes in slices
    of at most 1 MiB, one send per slice;
  - the receiver reads the 4 bytes and rejects a length above its own limit (at
    most 64 MiB) before it reads the body, then reads in a loop until it has
    that many bytes, and only then calls `Term.decode`. Both reads may return
    fewer bytes than asked: `TCP.recv_bytes` returns what is available, and
    `Process.read_bytes` returns fewer at EOF. EOF before the end is an error;
  - a small helper module (for example `std/frame`) can hold these two loops
    once `Bytes` lands; it is not part of this plan. The 4-byte length itself
    needs no new module: `std/binary` writes it and checks it against a
    limit.

### 16.8 Dependencies

- **`Bytes` first.** Today binary data is `List[Int]` (`IO.read_bytes`,
  `String.from_bytes`, `Process.send_bytes`). `Bytes` is in §12.5 "Later" and
  has no plan yet; it must be planned there, and landed, before this section
  starts. That plan must also say how the byte builtins take and return `Bytes`,
  and give a slice and a concat, so the framing loops above are easy to write.
- **Generic structs** (§15.3, roadmap 10c), since the type check substitutes the
  type arguments of generic instances (16.3).
- **The JSON form of enums** (§15.4, roadmap 10d), for the shared tag and values
  order. This section spells out its own form (16.4), so it does not need §15.4
  to be read; it lands after 10d so both formats agree from the start.
- It starts only when a real program needs it, for example a disk cache or
  messages between Agentica processes.

### 16.9 Not planned

- **Functions and handles:** a `Fn` may capture handles, and a handle (`Task`,
  `Table`, `FileHandle`, `Process`, `Socket`) is only valid inside the run that
  made it.
- **Untyped decode:** it is the `binary_to_term` attack surface; the target type
  is what keeps decode safe.
- **Erlang distribution** (transparent messages between nodes): Agentica
  processes talk through pipes or TCP with explicit `Term.encode` and
  `Term.decode`, so failures stay visible as Results.

### 16.10 Implementation (row 18)

- One PR on the VM: `Term.encode`/`Term.decode` per §16.4 with enums as
  `[tag, values]` (§16.5 for hostile input); the Term type check with
  substituted type arguments; `Term` becomes a reserved name. Needs `Bytes`,
  generic structs (10c) and the JSON form of enums (10d) first.
- Done when: an example writes a struct with an `Int`-keyed map, a Float NaN and
  an enum to bytes and reads it back, with the same bytes and output on the VM;
  every hostile-input case returns `error(...)`.
