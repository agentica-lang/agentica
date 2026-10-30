---
title: JSON
weight: 3
description: Encode values as JSON, decode JSON into structs, and read dynamic JSON.
---

Two ways to work with JSON:

- For a known shape, declare a struct. `JSON.encode` writes it and `JSON.decode` reads it back, with type checks.
- For data whose shape changes, use the `Json` type and the `JSON` functions to build and read it.

`Json`, `JSON` and `JsonField` are reserved names. A `Json` value has no constructor, equality, fields or indexing. It prints as JSON text with `puts`, `to_s`, interpolation and `JSON.encode`; `inspect` and `IO.inspect` show `<Json>`, also inside a list. A parsed object writes its keys sorted (see `JSON.parse`). A built object's key order is not fixed, while structs and maps keep theirs. Functions whose first parameter is a `Json` are also methods: `JSON.get(j, "a")` is `j.get("a")`.

## JSON.encode

```text
JSON.encode(value: T) -> String
```

Writes compact JSON. It takes numbers, `Bool`, `String`, `nil`, `Json`, lists, maps with `String` keys, structs and [Optionals](#optional-values) of those. Struct fields keep their declaration order and map entries their insertion order. An instance of a generic struct counts by its fields after substitution (`Box[List[Int]]`). `Result` values, other enums and `Int`-keyed maps are `CHECK-NOT-ENCODABLE`, and an untyped empty container needs an annotation. A non-finite `Float` stops the program with `RUNTIME-JSON-ENCODE`; it is never written as `null`. A `JsonField` field (see [optional and nullable fields](#optional-and-nullable-fields)) writes nothing when it is `Absent`.

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

```text
JSON.decode(s: String, type: T) -> Result[T]
JSON.decode(json: Json, type: T) -> Result[T]
```

Reads JSON into a struct. The first argument is JSON text or a `Json` value, the second the struct's name: a named struct type, not a value. A bare type name is valid only for `decode`, `schema` and `codec`. Fields may be `Int`, `Float`, `Bool`, `String`, lists, `String`-keyed maps, nested or recursive structs, and `Optional` and `JsonField` of those; any other nested type, a generic struct or enum instance included, is `CHECK-NOT-DECODABLE`. Malformed JSON, missing fields, wrong types, `Int` overflow and non-finite numbers give an error Result with a field or index path. Extra keys are ignored. A JSON integer may decode as a `Float`; a decimal or an exponent never decodes as an `Int`. Decoded maps are in sorted key order. A `Json` value is read as it is, with the same rules and errors as its text, so there is no need to write it out with `JSON.encode` first.

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
error("y: expected required field")
```

## JSON.schema

```text
JSON.schema(type: T) -> Json
```

Describes a struct as a JSON Schema: an object schema with `properties` and `required`. `required` lists every field that is not a `JsonField` or an `Optional`, and is left out when no field is required (an empty struct too). `Int` bounds are signed 64-bit, lists use `items`, `String`-keyed maps use `additionalProperties`, and nested and recursive structs use `$defs` and `$ref`. Extra keys stay allowed.

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

## JSON.codec

```text
JSON.codec(type: T) -> JSON.Codec[T]
codec.decode(s: String) -> Result[T]
codec.decode(json: Json) -> Result[T]
codec.encode(value: T) -> String
codec.from(value: T) -> Json
```

A generic function cannot call `JSON.encode` or `JSON.decode` on its type parameter `T`. It takes a `JSON.Codec[T]` instead, and the caller passes `JSON.codec(User)`, which takes the struct names that `JSON.decode` takes. `decode`, `encode` and `from` work as `JSON.decode`, `JSON.encode` and `JSON.from` do for that struct: `codec.encode(x)` and `codec.from(x)` take an `x` of type `T`.

```agentica
struct User
  name: String
  age: Int
end

def body_as[T](body: String, codec: JSON.Codec[T]) -> Result[T]
  return codec.decode(body)
end

def show[T](codec: JSON.Codec[T], value: T) -> String
  return codec.encode(value)
end

def main() -> Void
  user = body_as("{\"name\": \"Ana\", \"age\": 25}", JSON.codec(User)).unwrap!
  puts(show(JSON.codec(User), user))
end
```

```output
{"name":"Ana","age":25}
```

A codec can be a parameter, a struct field or a list item, as a function value can. Like a function value, it cannot be printed or compared, and it cannot be a constant or an `ATS` value. `IO.inspect` refuses a value that holds a codec (`CHECK-TYPE-MISMATCH`; in a generic body, `IO.inspect(x)` of a `T` that is a codec prints the struct's name as a `String`), and `decode`, `encode` and `from` are written only as methods: `JSON.Codec.decode(c, text)` is `CHECK-UNKNOWN-NAME`.

## Optional values

An [`Optional[T]`](/library/data-structures/optional/) is JSON's `null` or a `T`: `none` writes `null` and `some(x)` writes `x`. `JSON.decode` reads `null` as `none`, and a missing key of an `Optional` field too; any other value is decoded as `T` and gives `some(...)`, with the error texts of `JsonField` (`age: expected signed 64-bit Int or null`, `tags[0]: expected String or null`). It works for a field, a list item, a map value, an `Optional` item and the whole value of `JSON.encode` and `JSON.from`; `JSON.decode`, `JSON.schema` and `JSON.codec` take a struct name, so a top-level `Optional` is decoded as a field of a struct. A `none` field keeps its key when encoded. `JSON.schema` writes an `Optional` field as `{"anyOf": [<schema of T>, {"type": "null"}]}`. `JSON.schema` leaves an `Optional` field out of `required` and allows `null`.

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

What `JSON.decode` gives encodes back to the same JSON, except that a missing key comes back as `null`. JSON has one `null`, so in an `Optional[Optional[T]]` the value `some(none)` writes `null` and reads back as `none`. `Optional[Nil]` is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`, since `some(nil)` would be written as `null`. Use `JsonField` (below) when a missing key and `null` mean different things; `Optional[JsonField[T]]` is `CHECK-JSON-FIELD-PLACE`, and `JsonField[Optional[T]]` is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`.

## Optional and nullable fields

Some APIs (tool calls, PATCH bodies, config files) tell three states of a key apart: the key is absent, it is `null`, or it has a value. A struct field of type `JsonField[T]` keeps them apart. It is a builtin enum with the variants `JsonField.Absent`, `JsonField.Null` and `JsonField.Value(x)`.

- `JSON.decode` gives `Absent` for a missing key, `Null` for `null`, and `Value(...)` for any other value, decoded as `T`. `Value` adds no step to an error path, so an error inside the value keeps its path and text (`address.zip: expected String`, `tags[0]: expected String`). Only when the value itself has the wrong kind does the message add "or null": `age: expected signed 64-bit Int or null`, `address: expected object or null`. A missing field that is not a `JsonField` is still "required field".
- `JSON.encode` and `JSON.from` leave out an `Absent` key, write `null` for `Null`, and write the value of `Value`.
- `JSON.schema` leaves the field out of `required` and allows `null`: `{"anyOf": [<schema of T>, {"type": "null"}]}`, with no `$defs` entry of its own.
- An object with only the struct's declared keys, with values in the form `encode` writes, decodes and encodes back to the same object, up to key order: an absent key stays absent and a `null` stays `null`. Extra keys are dropped, and an integer in a `Float` field comes back as `1.0`.

```agentica
struct UpdateUser
  name: JsonField[String]
  age: JsonField[Int]
end

def describe_age(age: JsonField[Int]) -> String
  text = ""
  case age
    JsonField.Absent -> text = "age: keep"
    JsonField.Null -> text = "age: clear"
    JsonField.Value(n) -> text = "age: set to #{n}"
  end

  return text
end

def show(text: String) -> Result[Void]
  update = try JSON.decode(text, UpdateUser)
  puts(describe_age(update.age))
  name = ""
  case update.name
    JsonField.Value(n) -> name = "set to #{n}"
    _ -> name = "keep"          # this API treats null like absent
  end

  puts("name: #{name}")
  puts(JSON.encode(update))
  return ok()
end

def main() -> Void
  for text in ["{}", "{\"age\": null}", "{\"name\": \"Ana\", \"age\": 30}"]
    Result.unwrap!(show(text))
  end

  reply = UpdateUser(name: JsonField.Value("Bo"), age: JsonField.Null)
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

The variants are always qualified (`JsonField.Value(x)`). `Absent` and `Null` need an expected type, like any nullary variant of a generic enum (`CHECK-ENUM-TYPE-INFERENCE` otherwise); a struct field gives one. A `case` needs the three arms or a `_` arm, which is how a program treats absent and null alike.

`JsonField` may only be the type of a struct field in a JSON type: in the type of a `JSON.decode` or `JSON.schema` target or of a `JSON.encode` or `JSON.from` argument. A list or map of them, an `Optional` item, a `JsonField[JsonField[T]]` or a bare `JsonField` passed to `JSON.encode` or `JSON.from` is `CHECK-JSON-FIELD-PLACE`, at the target or argument; so is `items: List[T]` when `T` is a `JsonField` (a type argument counts after substitution). In `Box[JsonField[Int]]` (`struct Box[T]` with `value: T`) the field is a direct `JsonField` field, but `items: List[T]` or `f: JsonField[T]` with that argument is `CHECK-JSON-FIELD-PLACE`; `JSON.decode` and `JSON.schema` still take no generic instance. This check comes first, so `List[JsonField[Nil]]` is `CHECK-JSON-FIELD-PLACE`. `JsonField[Nil]` as a field cannot be encoded or decoded (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`), since `Value(nil)` would look like `Null`. A bare `JsonField` target is `CHECK-UNKNOWN-TYPE`. Outside JSON it is an ordinary enum value: locals, parameters, lists and maps may hold it, it prints when `T` does (`JsonField.Value(30)`), and it has no `==`. A user `struct JsonField`, `enum JsonField` or `import ... as JsonField` is `CHECK-REDEFINED-NAME`.

## JSON.parse

```text
JSON.parse(s: String) -> Result[Json]
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

```text
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
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

```text
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
```

Take a plain value out of a `Json`. The wrong kind gives an error Result. `JSON.int` needs an integer within 64-bit bounds, so `1.0` is not an `Int`; `JSON.float` rounds to a finite binary64, and overflow is an error. Parsed integers may exceed `Int` until extracted. JSON `null` stays a `Json`.

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
  return name.string
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

```text
JSON.list(j: Json) -> Result[List[Json]]
```

Turns a JSON array into a list of `Json` values.

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

```text
JSON.kind(value: Json) -> String
```

Names the kind of a `Json` value: `"null"`, `"bool"`, `"int"`, `"float"`, `"string"`, `"array"` or `"object"`. It never fails. A number written without a fraction or exponent, or built from an Int, is `"int"`, even outside 64-bit bounds (then `JSON.int` still errors); any other number is `"float"`.

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

```text
JSON.null() -> Json
JSON.null?(value: Json) -> Bool
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

```text
JSON.from(value: T) -> Json
```

Turns a value that `JSON.encode` accepts into a `Json`, with the same rules and errors (a non-finite `Float` stops the program with `RUNTIME-JSON-ENCODE`). `null` and `false` stay distinct, and so do empty objects and empty arrays.

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

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
```

Build objects and arrays whose values have different types: `object` takes a `Map[String, Json]` and `array` a `List[Json]`.

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
