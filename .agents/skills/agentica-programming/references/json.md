# JSON

```text
JSON.object(fields: Map[String, JSON.Value]) -> JSON.Value
JSON.array(items: List[JSON.Value]) -> JSON.Value
JSON.from(value: T) -> JSON.Value
JSON.null() -> JSON.Value
JSON.null?(value: JSON.Value) -> Bool
JSON.kind(value: JSON.Value) -> String
JSON.node(value: JSON.Value) -> JSON.Node
JSON.schema(type: T) -> JSON.Value
JSON.decode(text: String, type: T) -> Result[T]
JSON.decode(json: JSON.Value, type: T) -> Result[T]
T.codec -> Codec[T]
codec.decode(text: String) -> Result[T]
codec.decode(json: JSON.Value) -> Result[T]
codec.encode(value: T) -> String
codec.from(value: T) -> JSON.Value
codec.members -> List[StructMember]
JSON.parse(text: String) -> Result[JSON.Value]
JSON.encode(value: T) -> String
JSON.get(json: JSON.Value, key: String) -> Result[JSON.Value]
JSON.at(json: JSON.Value, index: Int) -> Result[JSON.Value]
JSON.string(json: JSON.Value) -> Result[String]
JSON.int(json: JSON.Value) -> Result[Int]
JSON.float(json: JSON.Value) -> Result[Float]
JSON.bool(json: JSON.Value) -> Result[Bool]
JSON.list(json: JSON.Value) -> Result[List[JSON.Value]]
```

## Building

- `JSON.from` accepts the same recursively encodable data as `JSON.encode`; a
  non-finite Float halts with `RUNTIME-JSON-ENCODE` at the call.

## Schema and decoding

- `JSON.schema(User)`, `JSON.decode(text, User)` and `User.codec` take a
  named struct type, not a value (bare type names are valid only there). A
  schema is a `JSON.Value`, not text.
- `JSON.decode(text, List[User])` and `JSON.decode(text, Map[String, User])`
  read a top-level array or object in one call; `schema` and `codec` take only
  a named type.
- `JSON.decode` takes JSON text or a `JSON.Value` value (`JSON.decode(item,
  User)` for an item of a parsed document; no `JSON.encode` first).
- Decoded fields may be Int, Float, Bool, String, lists, String-keyed maps,
  nested or recursive structs and enums, and `Optional` and `JSON.Field` of
  those; other types, an instance of a generic struct or enum included, are
  `CHECK-NOT-DECODABLE`. `JSON.decode(text, Shape)`, `schema` and `Shape.codec`
  take an enum name too.
- An enum is a tagged object, `{"tag":"Rect","values":[1.0,2.0]}`: the variant
  name and its payloads in order. Encode writes both keys (a variant with no
  payload writes `"values":[]`); decode accepts a missing `values` for such a
  variant. Any user enum with encodable payloads can be encoded, generic
  instances included (`Maybe[Int]`); only non-generic ones are decodable. A
  `JSON.Field` in a payload is `CHECK-JSON-FIELD-PLACE`.
- `JSON.decode` returns errors, with field or index paths
  (`shapes[0].values[1]`), for malformed JSON, missing fields, wrong types, Int
  overflow and non-finite Floats. Extra object keys are ignored. An integer may
  decode as Float; a decimal or exponent value never decodes as Int.

## Generic code: codecs

A generic function may `JSON.encode(x)` or `JSON.from(x)` a value of type `T`
(or `List[T]`, `Map[String, T]`, `Optional[T]`, `Box[T]`): each call checks that
the type bound to `T` is encodable (`CHECK-NOT-ENCODABLE` at that argument, for
an `Fn`, `Bytes` or `Task`), and a generic caller that passes its `T` on carries
the check. `JSON.decode(text, T)` stays `CHECK-NOT-DECODABLE`: take a
`Codec[T]` parameter; the caller passes `User.codec`. `codec.decode`,
`encode` and `from` behave as `JSON.decode`, `JSON.encode` and `JSON.from` for
that type, and `codec.members` is `T.members` (empty for an enum). A codec is
like an `Fn` value: a parameter, field or list item, but no printing, `==`,
constant or `ATS` value. `Codec` is reserved (type name and import alias); `JSON.codec(T)` and
`JSON.Codec[T]` do not exist.

```ruby
struct User
  name: String
end

def body_as[T](body: String, codec: Codec[T]) -> Result[T] = codec.decode(body)

def main() -> Void
  user = body_as("{\"name\": \"Ana\"}", User.codec).unwrap!
  puts(User.codec.encode(user))
end
```

## Optional values

`Optional[T]` is `null` or a `T` anywhere a type is (field, list item, map
value, the whole value of `JSON.encode`).

- Encode: `none` writes `null` (the key stays), `some(x)` writes `x`.
- Decode: `null` and a missing key of an `Optional` field are `none`; a wrong
  kind reads `age: expected signed 64-bit Int or null`. Schema: not
  `required`, allows `null` (`anyOf`).
- `Optional[Nil]` is not encodable or decodable; `Optional[JSON.Field[T]]` is
  `CHECK-JSON-FIELD-PLACE`; `JSON.Field[Optional[T]]` is not encodable or
  decodable. Use `JSON.Field` only to tell a missing key from `null`.

## Optional and nullable fields

A field `age: JSON.Field[Int]` tells an absent key, `null` and a value apart.
The builtin enum has `JSON.Field.Absent`, `JSON.Field.Null` and
`JSON.Field.Value(x)`; match all three or use `_`.

- Decode: a missing key is `Absent`, `null` is `Null`, anything else is
  decoded as `T` into `Value`. A wrong kind reads `age: expected signed 64-bit
  Int or null`; an error inside the value keeps its own path (`address.zip:
  expected String`).
- Encode (`JSON.encode`, `JSON.from`): `Absent` leaves the key out, `Null`
  writes `null`. Schema: the field is not `required` and allows `null`
  (`anyOf`).
- Only as the direct type of a struct field: `List[JSON.Field[Int]]`, a map of
  them, `JSON.Field[JSON.Field[T]]` or `JSON.encode(field_value)` is
  `CHECK-JSON-FIELD-PLACE`. `JSON.Field[Nil]` is not encodable or decodable.
  A type argument counts after substitution: `Box[JSON.Field[Int]]` with
  `value: T` encodes `value` as a `JSON.Field` field, but `items: List[T]` with
  that argument is `CHECK-JSON-FIELD-PLACE`.

```ruby
struct Patch
  name: JSON.Field[String]
end

def main() -> Void
  patch = JSON.decode("{\"name\": null}", Patch).unwrap!
  case patch.name
    JSON.Field.Value(name) -> puts("rename to #{name}")
    JSON.Field.Null -> puts("clear the name")
    JSON.Field.Absent -> puts("keep the name")
  end

  puts(JSON.encode(Patch(name: JSON.Field.Absent)))   # {}
end
```

## JSON.Value values

- `JSON.Value` is opaque: no constructor, equality, fields, `j[key]` or
  `j[index]`. `j.to_s`, `"#{j}"`, `puts(j)` and `JSON.encode(j)` give the JSON
  text.
- `JSON.parse` needs exactly one value; empty input, malformed JSON and
  trailing content return errors. A repeated object key keeps its last value.
- `JSON.get` needs an object and a present key; `JSON.at` an array and an index
  in range. Anything else returns an error. `false` and `null` are present
  values.
- `JSON.string` and `JSON.bool` need that exact kind. `JSON.int` needs a signed
  64-bit integer (`1.0` and `1e0` are not Int). `JSON.float` accepts integers
  and decimal or exponent numbers and rejects overflow.
- `JSON.kind` returns `"null"`, `"bool"`, `"int"`, `"float"`, `"string"`,
  `"array"` or `"object"` and never fails. `1` and `-0` are `"int"` (even beyond
  Int bounds, where `JSON.int` still errors); `1.0` and `1e2` are `"float"`.
- `JSON.node` (or `json.node`) opens one level for a `case` over unknown JSON:
  `JSON.Node.Null`, `Bool(Bool)`, `Int(Int)`, `BigInt(String)` (an integer
  `JSON.int` refuses, as exact text), `Float(Float)`, `String(String)`,
  `Array(List[JSON.Value])`, `Object(Map[String, JSON.Value])` (keys sorted).
  It never fails and cannot be encoded or decoded.
- `JSON.list` returns elements as `JSON.Value` values, mixed arrays included.

## Encoding

- `JSON.encode` accepts Int, Float, Bool, String, Nil (as null), JSON.Value,
  lists, String-keyed maps, Optionals and structs (`JSON.Field` fields too),
  recursively. Results, other enums and Int-keyed maps are
  `CHECK-NOT-ENCODABLE`, even when empty or nested. Empty literals still need a
  known type.
- Output is compact. Structs follow declaration order; maps follow insertion
  order. A parsed object encodes with keys sorted by UTF-8 bytes, so
  `JSON.encode(JSON.parse(x))` is canonical: compare two JSON texts by their
  canonical forms (`1` is not `1.0`). Objects from `JSON.object` or `JSON.from`
  have no fixed order.

## Prefer structs for fixed shapes

Struct fields may differ in type; maps and lists hold one type. For a protocol
envelope, declare the struct (`struct RpcResponse` with `jsonrpc: String`, `id:
JSON.Value`, `result: JSON.Value`) and `puts(JSON.encode(RpcResponse(...)))`,
then `IO.flush()`, instead of wrapping every scalar with `JSON.from`.

- `ok` and `error` are reserved field names, so a JSON-RPC error envelope cannot
  be a struct: use a String-keyed map for the envelope and a typed struct for
  its nested code and message.
- Give fixed nested records typed fields. Keep `JSON.Value` for variable
  payloads or identifiers, and call `JSON.from(payload)` once at that boundary.
- `JSON.encode` takes structs and String-keyed maps directly; use builders for
  dynamic objects or mixed arrays. A generic `def emit[T](x: T)` can
  `JSON.encode(x)`.

```ruby
def greet_json(text: String) -> Result[String]
  root = try JSON.parse(text)
  member = try JSON.get(root, "name")
  name = try JSON.string(member)
  ok("hello, " + name)
end

def main() -> Void
  text = JSON.encode({"name": "Ana"})
  puts(greet_json(text).unwrap!)
end
```
