# JSON

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(value: Json) -> Bool
JSON.schema(type: T) -> Json
JSON.decode(s: String, type: T) -> Result[T]
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


JSON builders create Json values directly: object takes Map[String, Json],
array takes List[Json], and from accepts the same recursively encodable data
as JSON.encode. Non-finite Float conversion halts with RUNTIME-JSON-ENCODE.
Null and false remain distinct, as do empty objects and arrays.

JSON.schema(User) accepts the same named structs as JSON.decode and returns
an object schema with properties and required fields. Int schemas specify
signed 64-bit bounds; lists use items and String-keyed maps use
additionalProperties. Nested/recursive structs use $defs/$ref. Extra struct
keys remain allowed, matching decoding. Schema is a Json value, not text.

`JSON.decode(text, User)` returns Result[User]. Its second argument is a named
struct type, not a runtime value; bare type names are valid only for decode/schema.
Fields may contain Int, Float, Bool, String, lists, String-keyed maps, and nested
or recursive structs. Unsupported nested types give CHECK-NOT-DECODABLE.
Malformed JSON, missing fields, wrong types, Int overflow, or non-finite Float
conversion return errors with field/index paths. Extra object keys are ignored.
Integer JSON values may decode as Float; decimal/exponent values never decode
as Int. Maps decoded from JSON use sorted key order.


- Json is opaque: no constructor, equality, fields, or `j[key]` / `j[index]`. `IO.inspect` prints `<Json>`; `j.to_s`, `"#{j}"`, `puts(j)` and `JSON.encode(j)` give its JSON text.
- Parse requires exactly one JSON value, with optional surrounding space/tab/CR/LF. Empty input, malformed JSON, trailing content, bad Unicode escapes, raw control characters in strings, and non-finite parsed numbers return errors. Repeated object keys keep the last value.
- Get requires an object and a present key; at requires an array and a nonnegative index smaller than its length. Wrong kinds, missing keys, and bad indexes return errors. JSON false and null are present values, not missing-key sentinels.
- String/Bool extraction requires that exact kind. Int extraction requires a signed 64-bit integer; `1.0` and `1e0` are not Int. Float extraction accepts integers and decimal/exponent numbers, with normal binary64 rounding, and rejects conversion overflow. Parsed integers may exceed Int bounds until extracted.
- List extraction returns array elements as Json values, including heterogeneous arrays. Null stays inside Json; there is no null extractor yet.
- Encode accepts Int, Float, Bool, String, Nil (as null), Json, lists, String-keyed maps, and structs, recursively. Results and Int-keyed maps are `CHECK-NOT-ENCODABLE`, even if empty or nested. Empty literals still need a known type.
- Encoding is compact; structs follow declaration order, maps follow insertion order. Parsed Json object order is unspecified. Non-finite Floats halt with `RUNTIME-JSON-ENCODE` at the encode call.

## Prefer structs for fixed JSON shapes

Struct fields may have different types, while maps/lists are homogeneous.
For protocol envelopes, declare the shape and encode the struct directly rather
than building a `Map[String, Json]` and wrapping every scalar with `JSON.from`:

```ruby
struct RpcResponse
  jsonrpc: String
  id: Json
  result: Json
end

def reply(id: Json, result: Json) -> Void
  response = RpcResponse(jsonrpc: "2.0", id: id, result: result)
  puts(JSON.encode(response))
  IO.flush()
end
```

Use separate message shapes so only the appropriate fields are emitted.
`ok` and `error` are reserved field names, so a JSON-RPC error envelope cannot
be a struct: use a String-keyed map for that envelope and a typed struct for
its nested code/message payload. Give fixed nested records native typed fields too; retain
`Json` for variable payloads or identifiers and use `JSON.from(payload)` once
at that boundary. `JSON.encode` accepts structs and String-keyed maps directly;
`JSON.object` is not required before encoding. Use builders for dynamic object
shapes or heterogeneous JSON arrays, where the `Json` wrappers are useful.
For a shared stdio transport helper, accept encoded `String`, print it and flush;
there are no user generics or structural unions to accept arbitrary structs.

```ruby
def greet_json(text: String) -> Result[String]
  root = try JSON.parse(text)
  member = try JSON.get(root, "name")
  name = try JSON.string(member)
  return ok("hello, " + name)
end

def main() -> Void
  text = JSON.encode({"name": "Ana"})
  puts(Result.unwrap!(greet_json(text)))
end
```
