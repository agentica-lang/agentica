---
title: TOML (std)
weight: 5
description: The std/toml module, which reads and writes TOML 1.0 documents.
---

`std/toml` is written in Agentica and reads and writes all of TOML 1.0: `import Toml from "std/toml"`. `parse` makes a `Toml.Value` (a recursive enum), `encode` writes it back, `to_json` converts it so `JSON.decode` can fill a struct. Every function returns a `Result` and never halts, whatever the input.

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

- The root is always a `Table`, a `Map` that keeps keys in first-written order.
- `Int` is a signed 64-bit integer (a larger value is a parse error). `Float` holds `inf` and `nan`. Arrays may mix types.
- `DateTime` keeps its text as written (the language has no date type). Offset and local date-times, local dates (`1979-05-27`) and local times (`07:32:00`) are accepted, and the month, day (leap years), time and offset are checked, not converted. A leap second (`:60`) is accepted, and fractional seconds keep every digit.

## Reading

`Toml.parse` accepts TOML 1.0 and nothing else. A float magnitude above the largest float reads as `inf`, one below the smallest as zero, as in Python's `tomllib`. CRLF counts as one LF, also inside a multi-line string.

Errors: a duplicate key, a table defined twice, adding to an inline table or a static array, a dotted key that names a `[header]` table (or the reverse), `[[a]]` on a static array or table, control characters in strings and comments, and a lone carriage return.

`Toml.get(value, path)` reads a dotted path (`"package.name"`). A segment of plain digits (no sign, no leading zero) also indexes an array: `"bin.1.path"` is the second `[[bin]]`. A missing key gives an error naming it. A key that holds a dot cannot be reached this way: use `case` on the `Table`.

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

A parse error starts with the place, `line 3, column 7: expected '=' after key`. Lines and columns count from 1, columns in characters, not bytes. Messages are lowercase with no final period.

Arrays and inline tables nest at most 256 levels, and a key has at most 256 parts. Deeper input is an error at the bracket or key, never a halt.

## Writing

`Toml.encode` takes a `Table` (any other root is an error) and returns the document with a final newline, the same bytes for the same value.

- In each table: plain `key = value` lines first, then `[a.b]` sub-tables, then `[[a.b]]` arrays of tables, each group in `Map` order, so a scalar never lands inside a `[[...]]` section.
- A table with only sub-tables gets no header; an empty table does. An array that is not a direct table entry, or a table in a mixed array, is written inline.
- A key that is not bare (`A-Za-z0-9_-`) is quoted. Strings are basic strings with escapes; non-ASCII text stays as is.
- A float reads back the same, including `inf`, `-inf` and `nan`. An invalid `DateTime` is an error.
- `parse` of the output gives the same values, with keys possibly regrouped in the order above.
- The reader's limits apply (256 parts in a table path, 256 levels inline), so the output can always be read back. `Toml.to_json` stops at 2,048 levels. Deep values are errors, never halts.

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

`Toml.to_json` turns a `DateTime` into its string and keeps integers and floats apart (`port = 8080.0` does not decode into an `Int`). `inf` and `nan` have no JSON form: errors. `JSON.decode(json, Config)` then fills a struct, and its errors name the field path.

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
  return JSON.decode(json, Config)
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
