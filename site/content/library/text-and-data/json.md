---
title: JSON
weight: 3
description: Encode values as JSON, decode JSON into structs, and read dynamic JSON.
---

Two ways to work with JSON:

- For a known shape, declare a struct, or an [enum](#enums) for a choice between shapes. `JSON.encode` writes it and `JSON.decode` reads it back, with type checks.
- For data whose shape changes, use the `JSON.Value` type and the `JSON` functions to build and read it.

`JSON` is a reserved name; `JSON.Value` and `JSON.Field` are its members. A `JSON.Value` has no constructor, equality, fields or indexing. It prints as JSON text with `puts`, `to_s`, interpolation and `JSON.encode`; `inspect` and `IO.inspect` show `<JSON.Value>`, also inside a list. A parsed object writes its keys sorted (see `JSON.parse`). A built object's key order is not fixed, while structs and maps keep theirs. Functions whose first parameter is a `JSON.Value` are also methods: `JSON.get(j, "a")` is `j.get("a")`.

## JSON.encode

```signature
JSON.encode(value: T) -> String
```

Writes compact JSON. It takes numbers, `Bool`, `String`, `nil`, `JSON.Value`, lists, maps with `String` keys, structs, [enums](#enums) and [Optionals](#optional-values) of those. Struct fields keep their declaration order and map entries their insertion order. An instance of a generic struct or enum counts by its fields or payloads after substitution (`Box[List[Int]]`). `Result` values, builtin enums such as `TaskExit` and `Int`-keyed maps are `CHECK-NOT-ENCODABLE`, and an untyped empty container needs an annotation. A non-finite `Float` stops the program with `RUNTIME-JSON-ENCODE`; it is never written as `null`. A `JSON.Field` field (see [optional and nullable fields](#optional-and-nullable-fields)) writes nothing when it is `Absent`.

A parsed object writes its keys sorted by UTF-8 bytes, so `JSON.encode(JSON.parse(x))` is canonical: texts that differ only in whitespace, key order or repeated keys give the same text, while `1` and `1.0` stay different.

```agentica
struct User
  name: String
  age: Int
  tags: List[String]
end

def main() -> Void
  puts(JSON.encode(User(name: "Ana", age: 25, tags: ["admin"])))
  puts(JSON.encode({"a": 1, "b": 2}))
  puts(JSON.encode([nil, nil]))
end
```

```output
{"name":"Ana","age":25,"tags":["admin"]}
{"a":1,"b":2}
[null,null]
```

## JSON.decode

```signature
JSON.decode(text: String, type: T) -> Result[T]
JSON.decode(json: JSON.Value, type: T) -> Result[T]
```

Reads JSON into a struct or an [enum](#enums), or into a `List[T]` or `Map[String, T]` of such a type. The first argument is JSON text or a `JSON.Value`, the second the type: a named struct or enum type, or `List[T]` or `Map[String, T]` written as a type, not a value. A bare type is valid only for `decode`, `schema` and `codec`, and `schema` and `codec` take only a named type. Fields may be `Int`, `Float`, `Bool`, `String`, lists, `String`-keyed maps, nested or recursive structs and enums, and `Optional` and `JSON.Field` of those; any other nested type, a generic struct or enum instance included, is `CHECK-NOT-DECODABLE`. Malformed JSON, missing fields, wrong types, `Int` overflow and non-finite numbers give an error Result with a field or index path. Extra keys are ignored. A JSON integer may decode as a `Float`; a decimal or an exponent never decodes as an `Int`. Decoded maps are in sorted key order. A `JSON.Value` value is read as it is, with the same rules and errors as its text, so there is no need to write it out with `JSON.encode` first.

```agentica
struct User
  name: String
  age: Int
end

def main() -> Void
  good = JSON.decode("{\"name\": \"Ana\", \"age\": 25, \"extra\": true}", User)
  case good
    ok(user) -> puts("#{user.name} is #{user.age}")
    error(message) -> puts(message)
  end

  bad = JSON.decode("{\"name\": \"Bob\"}", User)
  puts(bad.ok?)
end
```

```output
Ana is 25
false
```

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  data = JSON.parse("{\"points\": [{\"x\": 1, \"y\": 2}, {\"x\": 3}]}").unwrap!
  for item in data.get("points").unwrap!.list.unwrap!
    puts(JSON.decode(item, Point))
  end
end
```

```output
ok(Point(x: 1, y: 2))
error("y: expected required field", kind: "json.decode")
```

A top-level JSON array or object of items decodes in one call. An error path starts at the index or key:

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  points = JSON.decode("[{\"x\": 1, \"y\": 2}, {\"x\": 3, \"y\": 4}]", List[Point]).unwrap!
  puts(points)
  puts(JSON.decode("{\"a\": {\"x\": 5}}", Map[String, Point]))
end
```

```output
[Point(x: 1, y: 2), Point(x: 3, y: 4)]
error("[\"a\"].y: expected required field", kind: "json.decode")
```

## JSON.schema

```signature
JSON.schema(type: T) -> JSON.Value
```

Describes a struct as a JSON Schema: an object schema with `properties` and `required`. An enum is described by a `oneOf` (see [enums](#enums)). `required` lists every field that is not a `JSON.Field` or an `Optional`, and is left out when no field is required (an empty struct too). `Int` bounds are signed 64-bit, lists use `items`, `String`-keyed maps use `additionalProperties`, and nested and recursive structs and enums use `$defs` and `$ref`. Extra keys stay allowed.

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  schema = JSON.schema(Point)
  puts(schema.get("required").unwrap!)
end
```

```output
["x","y"]
```

## T.codec

`User.codec` (on the type, without parentheses, as `User.members`) is the `Codec[User]` of a struct or enum that `JSON.decode` takes.

```signature
codec.decode(text: String) -> Result[T]
codec.decode(json: JSON.Value) -> Result[T]
codec.encode(value: T) -> String
codec.from(value: T) -> JSON.Value
codec.members() -> List[StructMember]
```

A generic function may call `JSON.encode` and `JSON.from` on a value of its type parameter `T` (or of `List[T]`, `Map[String, T]`, `Optional[T]`, or a generic struct or enum of `T`): each call of the function then checks that the type it binds to `T` can be written as JSON, and a call with an `Fn`, a `Bytes` or a `Task` is `CHECK-NOT-ENCODABLE` at that argument. A generic function that passes its `T` on carries the same check to its own callers.

```agentica
def to_json[T](value: T) -> String = JSON.encode(value)

def main() -> Void
  puts(to_json([1, 2]))
  puts(to_json({"ok": true}))
end
```

```output
[1,2]
{"ok":true}
```

`JSON.decode` needs the type at run time, so a generic function cannot call it on `T`. It takes a `Codec[T]` instead, and the caller passes `User.codec`, on the struct and enum names that `JSON.decode` takes. `decode`, `encode` and `from` work as `JSON.decode`, `JSON.encode` and `JSON.from` do for that type: `codec.encode(x)` and `codec.from(x)` take an `x` of type `T`. `codec.members` is the list that [`User.members`](/tour/structs/#list-the-fields) gives, empty for an enum, so generic code that needs the fields of a type needs no JSON.

```agentica
struct User
  name: String
  age: Int
end

def body_as[T](body: String, codec: Codec[T]) -> Result[T] = codec.decode(body)

def show[T](codec: Codec[T], value: T) -> String = codec.encode(value)

def main() -> Void
  user = body_as("{\"name\": \"Ana\", \"age\": 25}", User.codec).unwrap!
  puts(show(User.codec, user))
end
```

```output
{"name":"Ana","age":25}
```

A codec can be a parameter, a struct field or a list item, as a function value can. Like a function value, it cannot be printed or compared, and it cannot be a constant or an `ATS` value. `IO.inspect` refuses a value that holds a codec (`CHECK-TYPE-MISMATCH`; in a generic body, `IO.inspect(x)` of a `T` that is a codec prints the record of its name and members). `Codec` is reserved, as a type name and as an import alias (`import Codec from "..."` is `CHECK-REDEFINED-NAME`; pick another alias).

## Optional values

An [`Optional[T]`](/library/data-structures/optional/) is JSON's `null` or a `T`: `none` writes `null` and `some(x)` writes `x`. `JSON.decode` reads `null` as `none`, and a missing key of an `Optional` field too; any other value is decoded as `T` and gives `some(...)`, with the error texts of `JSON.Field` (`age: expected signed 64-bit Int or null`, `tags[0]: expected String or null`). It works for a field, a list item, a map value, an `Optional` item and the whole value of `JSON.encode` and `JSON.from`; `JSON.decode`, `JSON.schema` and `T.codec` take a struct name, so a top-level `Optional` is decoded as a field of a struct. A `none` field keeps its key when encoded. `JSON.schema` writes an `Optional` field as `{"anyOf": [<schema of T>, {"type": "null"}]}`. `JSON.schema` leaves an `Optional` field out of `required` and allows `null`.

```agentica
struct Server
  host: String
  port: Optional[Int] = none
  tags: List[Optional[String]]
end

def main() -> Void
  server = JSON.decode("{\"host\": \"a\", \"tags\": [\"x\", null]}", Server).unwrap!
  puts(server)
  puts(JSON.encode(server))
  puts(JSON.encode(server.with(port: some(8080))))
end
```

```output
Server(host: "a", port: none, tags: [some("x"), none])
{"host":"a","port":null,"tags":["x",null]}
{"host":"a","port":8080,"tags":["x",null]}
```

What `JSON.decode` gives encodes back to the same JSON, except that a missing key comes back as `null`. JSON has one `null`, so in an `Optional[Optional[T]]` the value `some(none)` writes `null` and reads back as `none`. Use `JSON.Field` (below) when a missing key and `null` mean different things. `Optional[Nil]`, `Optional[JSON.Field[T]]` and `JSON.Field[Optional[T]]` are rejected by the checker (see the [builtins reference](/reference/builtins/)).

## Optional and nullable fields

Some APIs (tool calls, PATCH bodies, config files) tell three states of a key apart: the key is absent, it is `null`, or it has a value. A struct field of type `JSON.Field[T]` keeps them apart. It is a builtin enum with the variants `JSON.Field.Absent`, `JSON.Field.Null` and `JSON.Field.Value(x)`.

- `JSON.decode` gives `Absent` for a missing key, `Null` for `null`, and `Value(...)` for any other value, decoded as `T`. `Value` adds no step to an error path, so an error inside the value keeps its path and text (`address.zip: expected String`, `tags[0]: expected String`). Only when the value itself has the wrong kind does the message add "or null": `age: expected signed 64-bit Int or null`, `address: expected object or null`. A missing field that is not a `JSON.Field` is still "required field".
- `JSON.encode` and `JSON.from` leave out an `Absent` key, write `null` for `Null`, and write the value of `Value`.
- `JSON.schema` leaves the field out of `required` and allows `null`: `{"anyOf": [<schema of T>, {"type": "null"}]}`, with no `$defs` entry of its own.
- An object with only the struct's declared keys, with values in the form `encode` writes, decodes and encodes back to the same object, up to key order: an absent key stays absent and a `null` stays `null`. Extra keys are dropped, and an integer in a `Float` field comes back as `1.0`.

```agentica
struct UpdateUser
  name: JSON.Field[String]
  age: JSON.Field[Int]
end

def describe_age(age: JSON.Field[Int]) -> String
  text = ""
  case age
    JSON.Field.Absent -> text = "age: keep"
    JSON.Field.Null -> text = "age: clear"
    JSON.Field.Value(n) -> text = "age: set to #{n}"
  end

  text
end

def show(text: String) -> Result[Void]
  update = try JSON.decode(text, UpdateUser)
  puts(describe_age(update.age))
  name = ""
  case update.name
    JSON.Field.Value(n) -> name = "set to #{n}"
    _ -> name = "keep" # this API treats null like absent
  end

  puts("name: #{name}")
  puts(JSON.encode(update))
  ok()
end

def main() -> Void
  for text in ["{}", "{\"age\": null}", "{\"name\": \"Ana\", \"age\": 30}"]
    Result.unwrap!(show(text))
  end

  reply = UpdateUser(name: JSON.Field.Value("Bo"), age: JSON.Field.Null)
  puts(JSON.encode(reply))
end
```

```output
age: keep
name: keep
{}
age: clear
name: keep
{"age":null}
age: set to 30
name: set to Ana
{"name":"Ana","age":30}
{"name":"Bo","age":null}
```

The variants are always qualified (`JSON.Field.Value(x)`), and `Absent` and `Null` need an expected type, which a struct field gives. A `case` needs the three arms or a `_` arm, which is how a program treats absent and null alike. `JSON.Field` may only be the direct type of a struct field in a JSON type; anywhere else in one is `CHECK-JSON-FIELD-PLACE`. The checker rules for `JSON.Field` and the other reserved names are in the [builtins reference](/reference/builtins/).

## Enums

A user enum is written as an object with the variant's name under `tag` and its payload items, in order, under `values`:

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

struct Drawing
  shapes: List[Shape]
end

def main() -> Void
  drawing = Drawing(shapes: [Shape.Circle(2.0), Shape.Rect(1.0, 3.0), Shape.Empty])
  text = JSON.encode(drawing)
  puts(text)
  puts(JSON.decode(text, Drawing).unwrap! == drawing)
end
```

```output
{"shapes":[{"tag":"Circle","values":[2.0]},{"tag":"Rect","values":[1.0,3.0]},{"tag":"Empty","values":[]}]}
true
```

- `JSON.encode` and `JSON.from` write both keys, `tag` first in the text; a variant with no payload writes `"values":[]`. They take any user enum whose payloads can be written, generic instances such as `Maybe[Int]` included.
- `JSON.decode(text, Shape)` and a struct field of type `Shape` read the same form. `values` may be left out for a variant with no payload, and extra keys are ignored, as for structs. Only a non-generic enum can be decoded, and only when its payloads can: an enum with a payload that `decode` refuses is `CHECK-NOT-DECODABLE`, as a generic instance such as `Maybe[Int]` anywhere in the target.
- An error gives the path as for a struct, with `values[i]` for a payload item, for an unknown or missing `tag`, a missing or wrong `values`, a wrong number of items or a wrong item.
- `JSON.schema(Shape)` gives a `oneOf` with an object for each variant: `tag` is `{"enum": ["Rect"]}`, and `values` is an array with `minItems` and `maxItems` set to the number of payload items and `prefixItems` with one schema each. A variant with no payload gets `"maxItems": 0` and only `tag` is required. An enum reached from a struct goes in `$defs`.
- A `JSON.Field` in a payload is `CHECK-JSON-FIELD-PLACE`: it belongs to a struct field.

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

def main() -> Void
  puts(JSON.decode("{\"tag\": \"Empty\"}", Shape))
  puts(JSON.decode("{\"tag\": \"Rect\", \"values\": [1.0]}", Shape))
  puts(JSON.decode("{\"tag\": \"Oval\"}", Shape))
end
```

```output
ok(Shape.Empty)
error("values: expected array of 2 items", kind: "json.decode")
error("tag: expected one of Circle, Rect, Empty", kind: "json.decode")
```

## JSON.parse

```signature
JSON.parse(text: String) -> Result[JSON.Value]
```

Reads exactly one JSON value of any shape, with optional surrounding whitespace (space, tab, CR, LF). Bad JSON gives an error Result: empty input, trailing content, invalid escapes, raw control characters and non-finite numbers are all errors.

```agentica
def main() -> Void
  data = JSON.parse("{\"items\": [1, 2, 3]}").unwrap!
  puts(data)
  puts(JSON.parse("{oops").ok?)
end
```

```output
{"items":[1,2,3]}
false
```

A parsed object keeps each key once (the last one wins) and sorts its keys, so `JSON.encode(JSON.parse(x))` gives one text per JSON value. Arrays keep their order, and `1` stays different from `1.0`.

```agentica
def main() -> Void
  a = JSON.encode(JSON.parse("{\"b\": [2, 1], \"a\": 1, \"a\": 3}").unwrap!)
  b = JSON.encode(JSON.parse("{\"a\":3,\"b\":[2,1]}").unwrap!)
  puts(a)
  puts(a == b)
end
```

```output
{"a":3,"b":[2,1]}
true
```

## JSON.get and JSON.at

```signature
JSON.get(json: JSON.Value, key: String) -> Result[JSON.Value]
JSON.at(json: JSON.Value, index: Int) -> Result[JSON.Value]
```

`get` reads a member of an object; `at` reads an element of an array. A missing key, a bad index or the wrong kind gives an error Result. JSON `false` and `null` are present values.

```agentica
def main() -> Void
  data = JSON.parse("{\"items\": [10, 20]}").unwrap!
  items = data.get("items").unwrap!
  puts(items.at(1).unwrap!)
  puts(data.get("nope").ok?)
end
```

```output
20
false
```

## JSON.string, JSON.int, JSON.float and JSON.bool

```signature
JSON.string(json: JSON.Value) -> Result[String]
JSON.int(json: JSON.Value) -> Result[Int]
JSON.float(json: JSON.Value) -> Result[Float]
JSON.bool(json: JSON.Value) -> Result[Bool]
```

Take a plain value out of a `JSON.Value`. The wrong kind gives an error Result. `JSON.int` needs an integer within 64-bit bounds, so `1.0` is not an `Int`; `JSON.float` rounds to a finite binary64, and overflow is an error. Parsed integers may exceed `Int` until extracted. JSON `null` stays a `JSON.Value`.

```agentica
def main() -> Void
  data = JSON.parse("{\"name\": \"Ana\", \"age\": 25, \"score\": 9.5, \"admin\": false}").unwrap!
  puts(data.get("name").unwrap!.string)
  puts(data.get("age").unwrap!.int)
  puts(data.get("score").unwrap!.float)
  puts(data.get("admin").unwrap!.bool)
  puts(data.get("name").unwrap!.int.ok?)
end
```

```output
ok("Ana")
ok(25)
ok(9.5)
ok(false)
false
```

With `try`, reading nested JSON stays short:

```agentica
def city(text: String) -> Result[String]
  root = try JSON.parse(text)
  address = try root.get("address")
  name = try address.get("city")
  name.string
end

def main() -> Void
  puts(city("{\"address\": {\"city\": \"Lima\"}}"))
  puts(city("{}").ok?)
end
```

```output
ok("Lima")
false
```

## JSON.list

```signature
JSON.list(json: JSON.Value) -> Result[List[JSON.Value]]
```

Turns a JSON array into a list of `JSON.Value` values.

```agentica
def main() -> Void
  data = JSON.parse("[1, \"two\", null]").unwrap!
  for item in data.list.unwrap!
    puts(item)
  end
end
```

```output
1
"two"
null
```

## JSON.kind

```signature
JSON.kind(value: JSON.Value) -> String
```

Names the kind of a `JSON.Value`: `"null"`, `"bool"`, `"int"`, `"float"`, `"string"`, `"array"` or `"object"`. It never fails. A number written without a fraction or exponent, or built from an Int, is `"int"`, even outside 64-bit bounds (then `JSON.int` still errors); any other number is `"float"`.

```agentica
def main() -> Void
  data = JSON.parse("[1, 1.0, 1e2, \"x\", null, {}]").unwrap!
  puts(data.list.unwrap!.map do |item| item.kind end)
end
```

```output
["int", "float", "float", "string", "null", "object"]
```

## JSON.null and JSON.null?

```signature
JSON.null() -> JSON.Value
JSON.null?(value: JSON.Value) -> Bool
```

```agentica
def main() -> Void
  n = JSON.null()
  puts(n)
  puts(JSON.null?(n))
  puts(JSON.null?(JSON.from(0)))
end
```

```output
null
true
false
```

## JSON.from

```signature
JSON.from(value: T) -> JSON.Value
```

Turns a value that `JSON.encode` accepts into a `JSON.Value`, with the same rules and errors (a non-finite `Float` stops the program with `RUNTIME-JSON-ENCODE`). `null` and `false` stay distinct, and so do empty objects and empty arrays.

```agentica
def main() -> Void
  j = JSON.from({"ok": true})
  puts(j)
  puts(j.get("ok").unwrap!.bool)
end
```

```output
{"ok":true}
ok(true)
```

## JSON.object and JSON.array

```signature
JSON.object(fields: Map[String, JSON.Value]) -> JSON.Value
JSON.array(items: List[JSON.Value]) -> JSON.Value
```

Build objects and arrays whose values have different types: `object` takes a `Map[String, JSON.Value]` and `array` a `List[JSON.Value]`.

```agentica
def main() -> Void
  person = JSON.object({"name": JSON.from("Ana")})
  mixed = JSON.array([JSON.from(1), JSON.from("two"), JSON.null()])
  puts(person)
  puts(mixed)
end
```

```output
{"name":"Ana"}
[1,"two",null]
```
