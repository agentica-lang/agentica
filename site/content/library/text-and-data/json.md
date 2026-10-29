---
title: JSON
weight: 3
description: Encode values as JSON, decode JSON into structs, and read dynamic JSON.
---

Two ways to work with JSON:

- For a known shape, declare a struct. `JSON.encode` writes it and `JSON.decode` reads it back, with type checks.
- For data whose shape changes, use the `Json` type and the `JSON` functions to build and read it.

`Json` values print as JSON text with `puts` and `to_s`; `inspect` shows `<Json>`, also inside a list. A parsed object writes its keys sorted (see `JSON.parse`). A built object's key order is not fixed, while structs and maps keep theirs. Functions whose first parameter is a `Json` are also methods: `JSON.get(j, "a")` is `j.get("a")`.

## JSON.encode

```text
JSON.encode(value: T) -> String
```

Writes compact JSON. It takes numbers, `Bool`, `String`, `nil`, `Json`, lists, maps with `String` keys, and structs. Struct fields keep their order. A `JsonField` field (see [optional and nullable fields](#optional-and-nullable-fields)) writes nothing when it is `Absent`.

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

Reads JSON into a struct. The first argument is JSON text or a `Json` value, the second the struct's name. Missing fields and wrong types give an error Result that names the field. Extra keys are ignored. A `Json` value is read as it is, with the same rules and errors as its text, so there is no need to write it out with `JSON.encode` first.

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

Describes a struct as a JSON Schema. `required` lists the fields that are not `JsonField`, and is left out when there are none.

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

A generic function cannot call `JSON.encode` or `JSON.decode` on its type parameter `T`. It takes a `JSON.Codec[T]` instead, and the caller passes `JSON.codec(User)`, which takes the struct names that `JSON.decode` takes. `decode`, `encode` and `from` work as `JSON.decode`, `JSON.encode` and `JSON.from` do for that struct.

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

A codec can be a parameter, a struct field or a list item, as a function value can. Like a function value, it cannot be printed or compared, and it cannot be a constant or an `ATS` value. `IO.inspect` refuses a value that holds a codec, and `decode`, `encode` and `from` are written only as methods: `JSON.Codec.decode(c, text)` is `CHECK-UNKNOWN-NAME`.

## Optional and nullable fields

Some APIs (tool calls, PATCH bodies, config files) tell three states of a key apart: the key is absent, it is `null`, or it has a value. A struct field of type `JsonField[T]` keeps them apart. It is a builtin enum with the variants `JsonField.Absent`, `JsonField.Null` and `JsonField.Value(x)`.

- `JSON.decode` gives `Absent` for a missing key, `Null` for `null`, and `Value(...)` for any other value, decoded as `T`. A value of the wrong kind gives an error such as `age: expected signed 64-bit Int or null`.
- `JSON.encode` and `JSON.from` leave out an `Absent` key, write `null` for `Null`, and write the value of `Value`.
- `JSON.schema` leaves the field out of `required` and allows `null`: `{"anyOf": [<schema of T>, {"type": "null"}]}`.

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

`JsonField` may only be the type of a struct field in a JSON type. A list or map of them, a `JsonField[JsonField[T]]` or a bare `JsonField` passed to `JSON.encode` is `CHECK-JSON-FIELD-PLACE`; so is `items: List[T]` when `T` is a `JsonField` (a type argument counts after substitution). `JsonField[Nil]` cannot be encoded or decoded, since `Value(nil)` would look like `Null`. Outside JSON it is an ordinary enum value, and `JsonField` is a reserved name.

## JSON.parse

```text
JSON.parse(s: String) -> Result[Json]
```

Reads one JSON value of any shape. Bad JSON gives an error Result.

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

`get` reads a member of an object; `at` reads an element of an array. A missing key, a bad index or the wrong kind gives an error Result.

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

Take a plain value out of a `Json`. The wrong kind gives an error Result.

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

Turns a value that `JSON.encode` accepts into a `Json`.

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

Build objects and arrays whose values have different types.

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
