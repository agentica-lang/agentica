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
between Agentica processes (over `Process.spawn` pipes), and a snapshot of an
`ATS` table through `ATS.to_map` (the "Shared tables" section of
`docs/grammar/06c-tasks-and-tests.md`).

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

- The check is a new walk in the checker. `data-type?` (§13) cannot be reused:
  it accepts `Json`, `Result` and type variables, which Term must reject, and its
  `seen` key `(kind . name)` has no type arguments, so after `Box[Int]` it would
  skip `Box[String]`. The new walk goes through list elements, `Map` keys and
  values, struct fields and enum payloads; for a generic instance it substitutes
  the type arguments into the field and payload types first. Recursion is cut by
  a `seen` set keyed on the substituted type (kind, name, type arguments), so
  `Tree[Int]` stops when it meets `Tree[Int]` again while `Box[Int]` and
  `Box[String]` are checked apart.
- `Json`, `Result`, `Void` and `Fn` are rejected at any depth (`Box[Json]`,
  `List[Result[Int]]`, `Map[String, Fn[Int, Int]]`). `Json` has its own text form
  (`JSON.encode` it first); `Result` is for error flow, not stored data (use a
  user enum).
- **Concrete types only:** the argument of `encode` has a concrete static type,
  as `JSON.encode` requires. The checker already gives this at every call site
  (`CHECK-ENUM-TYPE-INFERENCE`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`);
  a type variable left after substitution that reaches `Term.encode` or a
  `decode` target is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE` (the `T` in
  the declaration of `Box[T]` is fine when the instance is `Box[Int]`). Encode
  never falls back to the run-time shape.
- Codes: a type that fails the rule is `CHECK-NOT-ENCODABLE` (`encode`) or
  `CHECK-NOT-DECODABLE` (`decode` target), with the span on the argument, as for
  JSON.
- Unlike JSON, `Map` keys may be `Int` (key types stay `Int` or `String`,
  `CHECK-MAP-KEY-TYPE`). `Nil` is allowed.
- **Generic instances** (`Option[Int]`, `Box[String]`) are allowed inside the
  type, checked after substitution. JSON decode rejects them only because its
  schema keys `$defs` by the bare type name (the grammar, "Generic structs");
  CBOR has no schema. A generic instance as the direct `decode` target stays out
  (`Option[Int]` in argument position reads as indexing, and a bare `Option` is
  `CHECK-UNKNOWN-TYPE`): wrap it in a struct.

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

- **Int:** decode rejects values outside signed 64-bit; bignum tags (2, 3) are
  rejected like any tag.
- **Float:** always 8 bytes, so the bits are exact and a `Float` never comes back
  as an `Int`. Infinities and `-0.0` keep their IEEE form; every NaN is written
  as the quiet NaN `0x7FF8000000000000`, so the same bytes come out whatever the
  host's NaN payload. Decode reads a `Float` only from the 8-byte form.
- **String:** invalid UTF-8 is rejected on decode, with the rule of the `.agcb`
  loader (`docs/vm/08-loader-and-cli.md` §8).
- **Map:** encode keeps insertion order and decode the order of the bytes, so a
  round trip keeps the order (`JSON.decode` sorts keys). Duplicate keys are
  rejected on decode; keys must match `K` (text for `String`, major 0/1 for
  `Int`).
- **Struct:** a map from field name to value, not an array in field order: an
  array is smaller but any change of fields breaks old data, silently when two
  fields have the same type (the values swap). Decode accepts keys in any order
  and rejects duplicates, known field or not; an ignored value is only read with
  the size, depth and item checks (16.5), not checked for duplicate keys. Removing
  or reordering fields is safe (extra keys are ignored, as in `JSON.decode`).
  **Adding a field breaks old data**: a default only fills a constructor, not a
  decode, so a missing field is an error (16.6).
- **Enum:** a CBOR array of exactly 2 items, `[tag, values]`: `tag` is the
  variant name without the enum name (`"Circle"`), `values` an array of the
  payloads in declaration order, always present (`["Empty", []]`). `Circle(2.0)`
  is `82 66 "Circle" 81 FB 4000000000000000`. Decode finds the variant in the
  target enum and reads exactly as many values as it has payloads; an unknown
  tag, a wrong length or a malformed outer array is an error. Error paths are
  `<enum path>.values[i]`. This is the tag and values order of the JSON form of
  enums (§15.4) written as an array; the two must not drift apart.
- **Deterministic encoding** (RFC 8949 §4.2): shortest heads and definite lengths
  only, so the same value built the same way gives the same bytes. Two rules of
  §4.2.1 are not followed, on purpose: map keys keep insertion order (an
  Agentica `Map` is ordered, so the order is part of the value; `{1: 10, 2: 20}`
  and `{2: 20, 1: 10}` differ), and floats always take 8 bytes.
- **Decode accepts only what encode writes**, except that struct keys may come in
  any order and extra struct keys are ignored. It rejects indefinite lengths,
  every tag, other simple values, a non-shortest head, non-8-byte floats, other
  NaNs and trailing bytes; an ignored struct value is still checked as well
  formed. Reading CBOR from other programs is not a goal; JSON covers interop.
- **Round trips:** `decode(encode(v))` gives `v` (compared by bytes or printed
  output; every NaN comes back as the one canonical NaN). Whatever `encode`
  returns as `ok`, `decode` reads with the same type, since both keep the same
  limits (16.5). `encode(decode(b))` gives back `b` only when `b` is canonical;
  otherwise struct keys come back in declaration order and ignored keys are gone.

### 16.5 Untrusted input

`Term.decode` treats its bytes like the `.agcb` loader treats a file
(`docs/vm/08-loader-and-cli.md` §8): they may come from another process or a
file anyone could write.

- **Depth:** at most 10,000 levels, the call depth limit. Depth counts Agentica
  value nesting, not CBOR nesting: the top value is at depth 1 and each element,
  key, value, field or payload is one deeper than its container. An enum is one
  level though it is two CBOR arrays (for `W(v: Some(Some(1)))` the `1` is at
  depth 4, not 6). Encode and decode count the same way (decode knows where an
  enum starts from the target type). An ignored struct value has no Agentica
  type, so each CBOR array or map counts as one level there. Depth is checked
  when a container is entered, so 10,000 is accepted and 10,001 is an error. The
  VM walks with an explicit stack, never C recursion
  (`docs/vm/05-values-execution-builtins.md` §7.3).
- **Lengths before allocation:** every length is checked against the bytes left
  before anything is allocated. Each item takes at least one byte, so an array
  of `n` items needs at least `n` bytes left, a map of `n` entries at least
  `2n`, and a byte or text string exactly its length. All sums use `uint64_t`
  and the form `size > limit - total`.
- **Item cap:** one input byte (an empty array, `0xF6`, a small Int) can become a
  value of some tens of bytes, so 64 MiB of input could build a few GiB. Decode
  therefore counts the values it reads, each Agentica value one item (the top
  value, each field value, list element, map key and value, enum value (its two
  arrays count once) and payload; inside an ignored struct value every CBOR item
  counts). Past `TERM_MAX_ITEMS` = 4,000,000 it stops with `$: too many items`;
  encode counts the same way. So `Wrap(items: xs)` has 2 + `n` items and the
  largest list is 3,999,998 elements; for more data, encode chunks as separate
  values. The worst case is about 4,000,000 times the size of the largest small
  value (some hundreds of MiB), plus strings and byte strings, which the input
  bounds.
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
- **Map keys in paths:** an `Int` key in decimal (`hits[3]`); a `String` key in
  double quotes with JSON escaping, as `JSON.decode` writes it
  (`users["a\"b"]`).
- **Paths are built only on error** from a stack of segments pushed and popped
  per level, so the cost stays linear in the input. Depth and item-cap errors use
  the root path (`$: depth limit exceeded`, `$: too many items`), in both
  directions.
- **Encode keeps the same limits and returns errors too:** more than the depth
  limit, more than `TERM_MAX_ITEMS` values, or over 64 MiB gives `error(...)`,
  never a halt, since these depend on the size of the data, which a program
  cannot easily check before the call (unlike a non-finite Float in
  `JSON.encode`, `RUNTIME-JSON-ENCODE`). The size error has the path of the first
  value that crosses the limit (`cache["big"]: encoded size is larger than 64
  MiB`); encode stops writing as soon as a limit is passed. Only a named struct
  or enum can be the `decode` target (16.2), so a top-level `List[Int]`, `Int` or
  `nil` is wrapped in a struct on both sides.

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

- **VM:** an in-house C codec in `vm/`, with no new dependency. CBOR is small:
  one head byte, then 0, 1, 2, 4 or 8 bytes of argument.
- **Tests:** the RFC 8949 Appendix A vectors that fit the mapping, as fixed bytes;
  round trips both ways; the depth and item-cap boundaries on encode and decode;
  encode errors with their paths; and hostile input (truncation at every byte,
  lengths larger than the input, duplicate keys, tags, indefinite lengths,
  non-shortest heads, invalid UTF-8, Ints outside int64, trailing bytes). The VM
  loader fuzzer gets a decode target too.
- **Framing:** decode rejects trailing bytes, so a stream needs framing. A
  message can be 64 MiB, but `Process.send_bytes` and `TCP.send_bytes` take at
  most 1 MiB per call and the read calls at most 1,048,576. So the sender writes
  a 4-byte big-endian length (`std/binary`) then the bytes in slices of at most
  1 MiB; the receiver reads the 4 bytes, rejects a length above its limit (at
  most 64 MiB) before reading the body, reads until it has that many bytes (a
  read may return fewer; EOF before the end is an error), and only then calls
  `Term.decode`. A helper module (`std/frame`) could hold the loops; it is not
  part of this plan.

### 16.8 Dependencies

- **Generic structs** (roadmap 10c; the grammar's "Generic structs"), since the
  type check substitutes the type arguments of generic instances (16.3).
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
  substituted type arguments; `Term` becomes a reserved name. Needs the JSON
  form of enums (10d) first.
- Done when: an example writes a struct with an `Int`-keyed map, a Float NaN and
  an enum to bytes and reads it back, with the same bytes and output on the VM;
  every hostile-input case returns `error(...)`.
