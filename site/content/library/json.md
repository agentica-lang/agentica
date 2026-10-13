---
title: JSON
weight: 8
description: Encode values as JSON, decode JSON into structs, and read dynamic JSON.
---

There are two ways to work with JSON:

- For a known shape, declare a struct. `JSON.encode` writes it and
  `JSON.decode` reads it back, with type checks.
- For data whose shape changes, use the `Json` type and the `JSON` functions to
  build and read it.

`Json` values print as JSON text with `puts` and `to_s`; `inspect` shows `<Json>`, also inside a list. A parsed JSON object writes its keys sorted
(see `JSON.parse`); the order of keys in a built JSON object is not fixed;
structs and maps keep their order. Functions whose first parameter is a `Json`
are also methods: `JSON.get(j, "a")` is `j.get("a")`.

## JSON.encode

```text
JSON.encode(value: T) -> String
```

Writes compact JSON. It takes numbers, `Bool`, `String`, `nil`, `Json`, lists,
maps with `String` keys, and structs. Struct fields keep their order.

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
```

Reads JSON into a struct. The second argument is the struct's name. Missing
fields and wrong types give an error Result. Extra keys are ignored.

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

## JSON.schema

```text
JSON.schema(type: T) -> Json
```

Describes a struct as a JSON Schema.

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

A parsed object keeps each key once (the last one wins) and sorts its keys, so
`JSON.encode(JSON.parse(x))` gives one text per JSON value. Arrays keep their
order, and `1` stays different from `1.0`.

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

`get` reads a member of an object; `at` reads an element of an array. A
missing key, a bad index or the wrong kind gives an error Result.

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
