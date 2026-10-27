# TOML (`std/toml`)

`import Toml from "std/toml"`. Reads and writes all of TOML 1.0. Written in
Agentica; every function returns a `Result` and none halts, whatever the input.

```text
Toml.parse(text: String) -> Result[Toml.Value]
Toml.encode(value: Toml.Value) -> Result[String]
Toml.to_json(value: Toml.Value) -> Result[Json]
Toml.get(value: Toml.Value, path: String) -> Result[Toml.Value]

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

- Build and match variants with the alias: `Toml.Value.Str("x")`,
  `Toml.Value.Table(map)`, and `Toml.Value.Table(entries) ->` in a `case`. Enums
  have no `==`: compare with `case`.
- The root of `parse` is always a `Table`. A `Map` keeps the order its keys were
  written in. An `Int` is signed 64-bit (a larger literal is an error). `Float`
  can hold `inf` and `nan`; a float too big for a `Float` reads as `inf`.
- A `DateTime` is the text as written (offset date-time, local date-time, local
  date, local time); it is checked but not converted.
- A parse error starts with the place: `line 3, column 7: expected '=' after
  key` (lines and columns from 1, columns count characters). Arrays and inline
  tables nest at most 256 levels and a key has at most 256 parts; deeper is an
  error.
- `Toml.get(doc, "package.name")` reads a dotted path. A segment of plain digits
  (no sign, no leading zero) indexes an array (`"bin.1.path"`). A key holding a
  dot cannot be reached this way: use `case` on the `Table`.
- `encode` needs a `Table` root (else an error) and ends the text with a
  newline. In each table it writes plain `key = value` lines first, then `[a.b]`
  sections, then arrays that hold only tables as `[[a.b]]`, each group in `Map`
  insertion order, so the same value gives the same bytes. Keys that are not
  bare are quoted. A `DateTime` with invalid text is an error.
  `parse(encode(v))` gives the same values back, but the key order may be
  regrouped (plain keys first). Over 256 table parts or 256 inline levels is an
  error, and so is `to_json` over 2,048 levels.
- To fill a struct: `JSON.decode(try Toml.to_json(doc), Config)`. A `DateTime`
  becomes a string, `1.0` stays a float (so it does not decode into an `Int`
  field), and `inf` or `nan` is an error.

```ruby
import Toml from "std/toml"

struct Config
  name: String
  port: Int
end

def load(text: String) -> Result[Config]
  doc = try Toml.parse(text)
  json = try Toml.to_json(doc)
  return JSON.decode(json, Config)
end

def main() -> Void
  puts(load("name = \"web\"\nport = 8080\n").unwrap!.port)       # 8080
  puts(Toml.get(Toml.parse("[a]\nb = 1\n").unwrap!, "a.b"))     # ok(Value.Int(1))
  puts(Toml.parse("a = [1, 2\n"))                               # error("line 2, column 1: expected ',' or ']' in an array")
end
```
