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
T.codec -> Codec[T]
codec.decode(s: String) -> Result[T]
codec.decode(json: Json) -> Result[T]
codec.encode(value: T) -> String
codec.from(value: T) -> Json
codec.members -> List[StructMember]
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

- `JSON.from` accepts the same recursively encodable data as `JSON.encode`; a
  non-finite Float halts with `RUNTIME-JSON-ENCODE` at the call.

## Schema and decoding

- `JSON.schema(User)`, `JSON.decode(text, User)` and `User.codec` take a
  named struct type, not a value (bare type names are valid only there). A
  schema is a `Json` value, not text.
- `JSON.decode` takes JSON text or a `Json` value (`JSON.decode(item, User)` for
  an item of a parsed document; no `JSON.encode` first).
- Decoded fields may be Int, Float, Bool, String, lists, String-keyed maps,
  nested or recursive structs and enums, and `Optional` and `JsonField` of
  those; other types, an instance of a generic struct or enum included, are
  `CHECK-NOT-DECODABLE`. `JSON.decode(text, Shape)`, `schema` and `Shape.codec`
  take an enum name too.
- An enum is a tagged object, `{"tag":"Rect","values":[1.0,2.0]}`: the variant
  name and its payloads in order. Encode writes both keys (a variant with no
  payload writes `"values":[]`); decode accepts a missing `values` for such a
  variant. Any user enum with encodable payloads can be encoded, generic
  instances included (`Maybe[Int]`); only non-generic ones are decodable. A
  `JsonField` in a payload is `CHECK-JSON-FIELD-PLACE`.
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

def body_as[T](body: String, codec: Codec[T]) -> Result[T]
  return codec.decode(body)
end

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
- `Optional[Nil]` is not encodable or decodable; `Optional[JsonField[T]]` is
  `CHECK-JSON-FIELD-PLACE`; `JsonField[Optional[T]]` is not encodable or
  decodable. Use `JsonField` only to tell a missing key from `null`.

```ruby
struct Server
  host: String
  port: Optional[Int] = none
end

def main() -> Void
  server = JSON.decode("{\"host\": \"a\"}", Server).unwrap!
  puts(server.port)               # none
  puts(JSON.encode(server))       # {"host":"a","port":null}
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
  `j.to_s`, `"#{j}"`, `puts(j)` and `JSON.encode(j)` give the JSON text.
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
- `JSON.list` returns elements as `Json` values, mixed arrays included.

## Encoding

- `JSON.encode` accepts Int, Float, Bool, String, Nil (as null), Json, lists,
  String-keyed maps, Optionals and structs (`JsonField` fields too),
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
Json`, `result: Json`) and `puts(JSON.encode(RpcResponse(...)))`, then
`IO.flush()`, instead of wrapping every scalar with `JSON.from`.

- `ok` and `error` are reserved field names, so a JSON-RPC error envelope cannot
  be a struct: use a String-keyed map for the envelope and a typed struct for
  its nested code and message.
- Give fixed nested records typed fields. Keep `Json` for variable payloads or
  identifiers, and call `JSON.from(payload)` once at that boundary.
- `JSON.encode` takes structs and String-keyed maps directly; use builders for
  dynamic objects or mixed arrays. A generic `def emit[T](x: T)` can
  `JSON.encode(x)`.

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
