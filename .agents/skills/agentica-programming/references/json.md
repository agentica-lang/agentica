# JSON

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(value: Json) -> Bool
JSON.kind(value: Json) -> String
JSON.schema(type: T) -> Json
JSON.decode(s: String, type: T) -> Result[T]
JSON.decode(json: Json, type: T) -> Result[T]
JSON.codec(type: T) -> JSON.Codec[T]
codec.decode(s: String) -> Result[T]
codec.decode(json: Json) -> Result[T]
codec.encode(value: T) -> String
codec.from(value: T) -> Json
JSON.parse(s: String) -> Result[Json]
JSON.encode(value: T) -> String
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
JSON.list(j: Json) -> Result[List[Json]]
```

## Building

- `JSON.object` takes a `Map[String, Json]`, `JSON.array` a `List[Json]`.
  `JSON.from` accepts the same recursively encodable data as `JSON.encode`; a
  non-finite Float halts with `RUNTIME-JSON-ENCODE` at the `JSON.from` or
  `JSON.encode` call.
- Null and false stay distinct, and so do empty objects and empty arrays.

## Schema and decoding

- `JSON.schema(User)`, `JSON.decode(text, User)` and `JSON.codec(User)` take a
  named struct type, not a value (bare type names are valid only there). The
  schema has `properties` and `required` (left out when no field is required);
  Int schemas carry signed 64-bit bounds; lists use `items`; String-keyed maps
  `additionalProperties`; nested and recursive structs `$defs` and `$ref`. Extra
  struct keys stay allowed, as in decoding. A schema is a `Json` value, not
  text.
- `JSON.decode` takes JSON text or a `Json` value (`JSON.decode(item, User)` for
  an item of a parsed document, with the same errors; no `JSON.encode` first).
- Decoded fields may be Int, Float, Bool, String, lists, String-keyed maps,
  nested or recursive structs, and `JsonField` of those; other types, an
  instance of a generic struct or enum included, are `CHECK-NOT-DECODABLE`.
- `JSON.decode` returns errors, with field or index paths, for malformed JSON,
  missing fields, wrong types, Int overflow and non-finite Floats. Extra object
  keys are ignored. An integer may decode as Float; a decimal or exponent value
  never decodes as Int. Decoded maps use sorted key order.

## Generic code: codecs

A generic function cannot `JSON.encode(x)` or `JSON.decode(text, T)` its `T`
(`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`). Take a `JSON.Codec[T]`
parameter; the caller passes `JSON.codec(User)`. `codec.decode`, `encode` and
`from` behave as `JSON.decode`, `JSON.encode` and `JSON.from` for that struct.
A codec is like an `Fn` value: a parameter, field or list item, but no
printing, `inspect` (`IO.inspect` too), `==`, constant or `ATS` value. Its
methods have no function form (`JSON.Codec.decode(c, s)` is
`CHECK-UNKNOWN-NAME`).

```ruby
struct User
  name: String
end

def body_as[T](body: String, codec: JSON.Codec[T]) -> Result[T]
  return codec.decode(body)
end

def main() -> Void
  user = body_as("{\"name\": \"Ana\"}", JSON.codec(User)).unwrap!
  puts(JSON.codec(User).encode(user))
end
```

## Optional and nullable fields

A field `age: JsonField[Int]` tells an absent key, `null` and a value apart. The
builtin enum has `JsonField.Absent`, `JsonField.Null` and `JsonField.Value(x)`;
match all three or use `_`.

- Decode: a missing key is `Absent`, `null` is `Null`, anything else is
  decoded as `T` into `Value`. A wrong kind reads `age: expected signed 64-bit
  Int or null`; an error inside the value keeps its own path (`address.zip:
  expected String`).
- Encode (`JSON.encode`, `JSON.from`): `Absent` leaves the key out, `Null`
  writes `null`. Schema: the field is not `required` and allows `null`
  (`anyOf`).
- Only as the direct type of a struct field: `List[JsonField[Int]]`, a map of
  them, `JsonField[JsonField[T]]` or `JSON.encode(field_value)` is
  `CHECK-JSON-FIELD-PLACE`. `JsonField[Nil]` is not encodable or decodable.
  A type argument counts after substitution: `Box[JsonField[Int]]` with
  `value: T` encodes `value` as a `JsonField` field, but `items: List[T]` with
  that argument is `CHECK-JSON-FIELD-PLACE`.
  `JsonField` is a reserved name.

```ruby
struct Patch
  name: JsonField[String]
end

def main() -> Void
  patch = JSON.decode("{\"name\": null}", Patch).unwrap!
  case patch.name
    JsonField.Value(name) -> puts("rename to #{name}")
    JsonField.Null -> puts("clear the name")
    JsonField.Absent -> puts("keep the name")
  end
  puts(JSON.encode(Patch(name: JsonField.Absent)))   # {}
end
```

## Json values

- `Json` is opaque: no constructor, equality, fields, `j[key]` or `j[index]`.
  `IO.inspect` prints `<Json>`, `j.inspect` gives `"<Json>"`; `j.to_s`,
  `"#{j}"`, `puts(j)` and `JSON.encode(j)` give the JSON text.
- `JSON.parse` needs exactly one value, with optional surrounding space, tab, CR
  or LF. Empty input, malformed JSON, trailing content, bad Unicode escapes, raw
  control characters in strings and non-finite numbers return errors. A repeated
  object key keeps its last value.
- `JSON.get` needs an object and a present key; `JSON.at` an array and a
  nonnegative index below its length. Wrong kinds, missing keys and bad indexes
  return errors. JSON `false` and `null` are present values.
- `JSON.string` and `JSON.bool` need that exact kind. `JSON.int` needs a signed
  64-bit integer (`1.0` and `1e0` are not Int). `JSON.float` accepts integers
  and decimal or exponent numbers (binary64 rounding) and rejects overflow.
  Parsed integers may exceed Int bounds until extracted.
- `JSON.kind` returns `"null"`, `"bool"`, `"int"`, `"float"`, `"string"`,
  `"array"` or `"object"` and never fails. `1` and `-0` are `"int"` (even beyond
  Int bounds, where `JSON.int` still errors); `1.0` and `1e2` are `"float"`.
- `JSON.list` returns elements as `Json` values, mixed arrays included. Null
  stays inside `Json`; there is no null extractor.

## Encoding

- `JSON.encode` accepts Int, Float, Bool, String, Nil (as null), Json, lists,
  String-keyed maps and structs (`JsonField` fields too), recursively. Results,
  other enums and Int-keyed maps are
  `CHECK-NOT-ENCODABLE`, even when empty or nested. Empty literals still need a
  known type.
- Output is compact. Structs follow declaration order; maps follow insertion
  order. A parsed object encodes with keys sorted by UTF-8 bytes and each key
  once (the last duplicate wins), so `JSON.encode(JSON.parse(x))` is canonical:
  compare two JSON texts by their canonical forms, which ignore key order but
  keep array order and number kinds (`1` is not `1.0`). Objects from
  `JSON.object` or `JSON.from` have no fixed order.

## Prefer structs for fixed shapes

Struct fields may differ in type; maps and lists hold one type. For a protocol
envelope, declare the struct (`struct RpcResponse` with `jsonrpc: String`, `id:
Json`, `result: Json`) and `puts(JSON.encode(RpcResponse(...)))`, then
`IO.flush()`, instead of wrapping every scalar with `JSON.from`.

- Use a separate shape for each message kind, so only its fields are emitted.
- `ok` and `error` are reserved field names, so a JSON-RPC error envelope cannot
  be a struct: use a String-keyed map for the envelope and a typed struct for
  its nested code and message.
- Give fixed nested records typed fields. Keep `Json` for variable payloads or
  identifiers, and call `JSON.from(payload)` once at that boundary.
- `JSON.encode` takes structs and String-keyed maps directly, so `JSON.object`
  is not needed before encoding; use builders for dynamic objects or mixed
  arrays.
- A shared stdio helper takes the encoded `String`, prints it and flushes. There
  are no structural unions to accept any struct; a generic function encodes a
  `T` only through a `JSON.Codec[T]`.

```ruby
def greet_json(text: String) -> Result[String]
  root = try JSON.parse(text)
  member = try JSON.get(root, "name")
  name = try JSON.string(member)
  return ok("hello, " + name)
end

def main() -> Void
  text = JSON.encode({"name": "Ana"})
  puts(greet_json(text).unwrap!)
end
```
