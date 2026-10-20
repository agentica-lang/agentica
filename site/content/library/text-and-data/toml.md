---
title: TOML (std)
weight: 5
description: The std/toml module, which reads and writes TOML 1.0 documents.
---

`std/toml` is part of the standard library. It is written in Agentica itself and reads and writes all of TOML 1.0. Import it with an alias: `import Toml from "std/toml"`.

`Toml.parse` turns text into a `Toml.Value`, a recursive enum that models TOML's own values. `Toml.encode` writes a value back as text. `Toml.to_json` converts a value to `Json`, so that `JSON.decode` can fill a struct. Every function returns a `Result` and never halts, whatever the input.

```ruby
Toml.parse(text: String) -> Result[Toml.Value]
Toml.encode(value: Toml.Value) -> Result[String]
Toml.to_json(value: Toml.Value) -> Result[Json]
Toml.get(value: Toml.Value, path: String) -> Result[Toml.Value]
```

## Values

```ruby
enum Toml.Value
  Str(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
  DateTime(String)
  Array(List[Toml.Value])
  Table(Map[String, Toml.Value])
end
```

The root of a document is always a `Table`. A `Table` is a `Map`, so it keeps the keys in the order they were first written. An `Int` is a signed 64-bit integer: a larger value is a parse error. `Float` holds `inf` and `nan` too. Arrays may mix types, as TOML 1.0 allows.

A `DateTime` keeps its text as written, because the language has no date type yet. Offset and local date-times, local dates (`1979-05-27`) and local times (`07:32:00`) are accepted; the module checks the month, the day (leap years included), the time and the offset, but does not convert the value. A leap second (`:60`) is accepted, and fractional seconds keep every digit.

## Reading

`Toml.parse` accepts TOML 1.0 and nothing else:

- Keys: bare, quoted and dotted.
- Values: basic, literal and multi-line strings with all escapes (`\uXXXX`, `\UXXXXXXXX` and the backslash at a line end); integers in decimal, hex, octal and binary with `_`; floats with an exponent, `inf` and `nan`; booleans; date-times; arrays and inline tables. A magnitude above the largest float reads as `inf`, and one below the smallest as zero, as in Python's `tomllib`.
- Structure: standard tables, arrays of tables, comments and CRLF line ends. A CRLF counts as one LF, also inside a multi-line string.

Redefinitions are errors: a duplicate key, a table defined twice, adding to an inline table or a static array, a dotted key that names a `[header]` table (or the reverse), and `[[a]]` on a static array or table. Control characters in strings and comments, and a lone carriage return, are errors too.

`Toml.get(value, path)` reads a value by a dotted path (`"package.name"`). A segment of plain digits (no sign, no leading zero) also indexes an array, so `"bin.1.path"` reads the second `[[bin]]`. A missing key gives an error that names it. A key that itself holds a dot cannot be reached this way: use `case` on the `Table`.

```agentica
import Toml from "std/toml"

def main() -> Void
  text = "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[[bin]]\npath = \"a.agc\"\n\n[[bin]]\npath = \"b.agc\"\n"
  doc = Toml.parse(text).unwrap!
  puts(Toml.get(doc, "package.name"))     # a dotted path
  puts(Toml.get(doc, "bin.1.path"))       # digits index an array
  puts(Toml.get(doc, "package.license"))  # a missing key is an error
  puts(Toml.parse("a = 1\nb = 2\nc d\n")) # a parse error names its place
end
```

```output
ok(Value.Str("demo"))
ok(Value.Str("b.agc"))
error("no key \"license\" in \"package.license\"")
error("line 3, column 3: expected '=' after key")
```

## Errors

A parse error starts with the place: `line 3, column 7: expected '=' after key`. Lines and columns count from 1, and a column counts characters (code points), not bytes. The message is lowercase and has no final period. A text that is not valid UTF-8 cannot be a `String`, so it never reaches the parser.

Arrays and inline tables nest at most 256 levels, and a key (a table header or a dotted key) has at most 256 parts. A deeper input is an error at the opening bracket or at the key, not a halt, so a hostile file cannot stop a program.

## Writing

`Toml.encode` takes a `Table` and returns the document, with a final newline. Any other root is an error. The output is deterministic: the same value gives the same bytes.

- In each table, the plain `key = value` lines come first, then the sub-tables as `[a.b]` sections, then the arrays of tables as `[[a.b]]` sections. This holds whatever the order of the `Map`, so a scalar never lands inside the last `[[...]]` section. Each group keeps the `Map` order.
- A table with only sub-tables gets no header, and an empty table gets one. An array that is not a direct entry of a table, or a table in a mixed array, is written inline.
- A key that is not bare (`A-Za-z0-9_-`) is quoted. Strings are basic strings with escapes; non-ASCII text is written as it is.
- A float reads back as the same float, including `inf`, `-inf` and `nan`. A `DateTime` that is not a valid TOML date-time is an error.

`Toml.parse` of what `Toml.encode` wrote gives back the same values in the same Maps, but the order of the keys may be regrouped: plain entries first, then sub-tables, then arrays of tables.

The writer keeps the limits of the reader: a table path of more than 256 parts, or an inline value nested more than 256 levels, is an error, so what `encode` writes can always be read back. A value nested very deeply is an error, never a halt, and so is `Toml.to_json` beyond 2,048 levels.

```agentica
import Toml from "std/toml"

def main() -> Void
  pkg: Map[String, Toml.Value] = {"name": Toml.Value.Str("acme/text"), "deps": Toml.Value.Array([Toml.Value.Str("acme/lists")])}
  root: Map[String, Toml.Value] = {}
  root = root.put("package", Toml.Value.Array([Toml.Value.Table(pkg)]))
  root = root.put("version", Toml.Value.Int(1))
  text = Toml.encode(Toml.Value.Table(root)).unwrap!
  puts(text)
  puts(Toml.parse(text).ok?)
end
```

```output
version = 1

[[package]]
name = "acme/text"
deps = ["acme/lists"]

true
```

## Typed decoding

`Toml.to_json` converts a value to `Json`: a `DateTime` becomes its string, an integer stays an integer and a float stays a float (so `port = 8080.0` does not decode into an `Int`). `inf` and `nan` have no JSON form and are errors. `JSON.decode(JSON.encode(json), Config)` then fills a struct, and its errors name the field path.

```agentica
import Toml from "std/toml"

struct Limits
  cpu: Int
end

struct Config
  name: String
  port: Int
  limits: Limits
end

def load(text: String) -> Result[Config]
  doc = try Toml.parse(text)
  json = try Toml.to_json(doc)
  return JSON.decode(JSON.encode(json), Config)
end

def main() -> Void
  config = load("name = \"web\"\nport = 8080\n\n[limits]\ncpu = 4\n").unwrap!
  puts(config.name)
  puts(config.limits.cpu)
  puts(load("name = \"web\"\nport = 8080.0\n[limits]\ncpu = 4\n").message)
end
```

```output
web
4
port: expected signed 64-bit Int
```
