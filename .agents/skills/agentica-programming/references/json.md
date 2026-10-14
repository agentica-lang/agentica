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

## Building

- `JSON.object` takes a `Map[String, Json]`, `JSON.array` a `List[Json]`. `JSON.from` accepts the same recursively encodable data as `JSON.encode`; a non-finite Float halts with `RUNTIME-JSON-ENCODE`.
- Null and false stay distinct, and so do empty objects and empty arrays.

## Schema and decoding

- `JSON.schema(User)` and `JSON.decode(text, User)` take a named struct type, not a value; bare type names are valid only there. The schema has `properties` and `required`. Int schemas carry signed 64-bit bounds; lists use `items`; String-keyed maps use `additionalProperties`; nested and recursive structs use `$defs` and `$ref`. Extra struct keys stay allowed, as in decoding. A schema is a `Json` value, not text.
- Decoded fields may be Int, Float, Bool, String, lists, String-keyed maps, and nested or recursive structs. Other types give `CHECK-NOT-DECODABLE`.
- `JSON.decode` returns errors, with field or index paths, for malformed JSON, missing fields, wrong types, Int overflow, and non-finite Floats. Extra object keys are ignored. An integer may decode as Float; a decimal or exponent value never decodes as Int. Decoded maps use sorted key order.

## Json values

- `Json` is opaque: no constructor, equality, fields, or `j[key]` or `j[index]`. `IO.inspect` prints `<Json>`, and `j.inspect` gives `"<Json>"`. `j.to_s`, `"#{j}"`, `puts(j)`, and `JSON.encode(j)` give the JSON text.
- `JSON.parse` needs exactly one value, with optional surrounding space, tab, CR, or LF. Empty input, malformed JSON, trailing content, bad Unicode escapes, raw control characters in strings, and non-finite numbers return errors. A repeated object key keeps its last value.
- `JSON.get` needs an object and a present key. `JSON.at` needs an array and a nonnegative index below its length. Wrong kinds, missing keys, and bad indexes return errors. JSON `false` and `null` are present values.
- `JSON.string` and `JSON.bool` need that exact kind. `JSON.int` needs a signed 64-bit integer; `1.0` and `1e0` are not Int. `JSON.float` accepts integers and decimal or exponent numbers (binary64 rounding) and rejects overflow. Parsed integers may exceed Int bounds until extracted.
- `JSON.list` returns elements as `Json` values, including mixed arrays. Null stays inside `Json`; there is no null extractor.

## Encoding

- `JSON.encode` accepts Int, Float, Bool, String, Nil (as null), Json, lists, String-keyed maps, and structs, recursively. Results and Int-keyed maps give `CHECK-NOT-ENCODABLE`, even when empty or nested. Empty literals still need a known type.
- Output is compact. Structs follow declaration order; maps follow insertion order. A parsed object encodes with keys sorted by UTF-8 bytes and each key once (the last duplicate wins). So `JSON.encode(JSON.parse(x))` is canonical: compare two JSON texts by their canonical forms, which ignore key order but keep array order and number kinds (`1` is not `1.0`). Objects from `JSON.object` or `JSON.from` have no fixed order. A non-finite Float halts with `RUNTIME-JSON-ENCODE` at the encode call.

## Prefer structs for fixed shapes

Struct fields may differ in type; maps and lists hold one type. For a protocol envelope, declare the struct and encode it directly, instead of wrapping every scalar with `JSON.from`:

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

- Use a separate shape for each message kind, so only its fields are emitted.
- `ok` and `error` are reserved field names, so a JSON-RPC error envelope cannot be a struct. Use a String-keyed map for the envelope and a typed struct for its nested code and message.
- Give fixed nested records typed fields. Keep `Json` for variable payloads or identifiers, and call `JSON.from(payload)` once at that boundary.
- `JSON.encode` accepts structs and String-keyed maps directly, so `JSON.object` is not needed before encoding. Use builders for dynamic objects or mixed arrays.
- A shared stdio helper takes the encoded `String`, prints it, and flushes. There are no user generics or structural unions to accept any struct.

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
