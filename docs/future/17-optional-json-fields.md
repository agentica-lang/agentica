## 17. Optional and nullable JSON fields

APIs with JSON Schema inputs (tool calls, PATCH bodies, config files) often tell
three states of a key apart: the key is absent, the key is `null`, or the key
has a real value. Typed JSON cannot show this today. `JSON.decode`
fails on a missing key ("required field") and on `null`;
`JSON.schema` lists every field in `required`; `JSON.encode` and `JSON.from`
always write every field. `nil` does not help: `Nil` is not a nullable wildcard
(`grammar.md`). The only way is dynamic `Json`: `JSON.get` returns an error for
an absent key and `JSON.null?` finds `null`. This section adds a typed way. It
is item 10e (row 7.6); the plan checklist lives in §15.6.

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

Output:

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

- **The type.** `JsonField[T]` is a builtin generic enum:

  ```agentica
  enum JsonField[T]
    Absent
    Null
    Value(T)
  end
  ```

  The variants are always qualified (`JsonField.Value(x)`), so they do not clash
  with user enums. `Absent` and `Null` are nullary and need an expected type,
  like any nullary variant of a generic enum (`CHECK-ENUM-TYPE-INFERENCE`
  otherwise); a struct field gives one.
- **Decode** (`JSON.decode`), for a struct field of type `JsonField[T]`: a
  missing key gives `Absent`; JSON `null` gives `Null`; any other value is
  decoded as `T` and gives `Value(...)`. The error rule: `Value` adds no path
  step, so an error inside the value keeps today's path and text (`address.zip:
  expected String` under `address: JsonField[Address]`, `tags[0]: expected
  String` under `tags: JsonField[List[String]]`). Only when the `JsonField`
  field's own value has the wrong kind does the message add "or null": `age:
  expected signed 64-bit Int or null`, `address: expected object or null`. This
  happens at the `JsonField` level only: an inner failure is not rewritten. The
  field level checks the top kind of the value itself (the check `decode` makes
  for `T` before it goes deeper) and fails with the "or null" text, then decodes
  the value as `T`. Fields that are not `JsonField` still fail with "required
  field" when missing. Extra keys are still ignored.
- **Encode** (`JSON.encode`, `JSON.from`): `Absent` leaves the key out, `Null`
  writes `null`, `Value(x)` writes `x` as today. The other keys keep struct
  declaration order.
- **No `JsonField[Nil]`.** `Value(nil)` would write `null` and could not be told
  apart from `Null`, so every JSON builtin rejects `JsonField[Nil]`: it is
  `CHECK-NOT-ENCODABLE` in a `JSON.encode` or `JSON.from` argument and
  `CHECK-NOT-DECODABLE` in a `JSON.decode` or `JSON.schema` target. The
  placement check still runs first (see "Which code wins").
- **Schema** (`JSON.schema`): a `JsonField[T]` field is left out of `required`,
  and its property schema is `{"anyOf": [<schema of T>, {"type": "null"}]}`. No
  `$defs/JsonField` entry is made. `anyOf` and the `"null"` type work in every
  draft, and the form is the same when `T` is a `$ref` to a struct. When no
  field of a struct is required, `required` is left out, because draft-04 needs
  a non-empty list. This also changes structs with no fields: today they get
  `"required": []`, and after 10e they get no `required` key. So `required` is
  left out for any struct with no required field: empty structs and structs
  whose fields are all `JsonField`. It is a schema change; say so in the
  changelog. Programs that read `required` without checking can break (the JSON
  site page's `Point` example has required fields, so it still works).

  For `UpdateUser`:

  ```json
  {"type": "object",
   "properties": {"name": {"anyOf": [{"type": "string"}, {"type": "null"}]},
                  "age": {"anyOf": [{"type": "integer",
                                     "minimum": -9223372036854775808,
                                     "maximum": 9223372036854775807},
                                    {"type": "null"}]}}}
  ```

- **Round trip:** for an object that has only the struct's declared keys, with
  values in the form encode writes, decoding it and encoding the result gives
  back the same object, up to key order (the encoded text follows declaration
  order). An absent key stays absent and a `null` stays `null`. Other input does
  not come back unchanged, as today: extra keys are dropped, and an integer
  decoded into a `Float` field comes back as `1.0`.
- **`case`:** the three variants need three arms, or a `_` arm. `_` is how a
  program merges absent and null when its API does not tell them apart.
- **Where it is allowed in JSON.** In the type of a JSON builtin target
  (`JSON.decode`, `JSON.schema`) or argument (`JSON.encode`, `JSON.from`),
  `JsonField[T]` is allowed only as the direct type of a struct field. Absent
  and null are about an object key, and only struct fields are object keys with
  a fixed name. Everywhere else in that type it is `CHECK-JSON-FIELD-PLACE` (new
  code):
  - an item of a list (`List[JsonField[Int]]`) or a map value
    (`Map[String, JsonField[Int]]`): a list has no key to leave out, and a map
    already shows absence by not having the key;
  - a nested `JsonField[JsonField[T]]`: there is no fourth state;
  - an enum payload, once enums have a JSON form (§15.4);
  - the whole argument of `JSON.encode` or `JSON.from` (`JSON.encode(f)` where
    `f: JsonField[Int]`).

  A decode or schema target cannot be `JsonField` itself: a bare `JsonField`
  with no type arguments is `CHECK-UNKNOWN-TYPE`, as for any generic name today.
  `T` itself must be decodable (or encodable) as today, or the call is
  `CHECK-NOT-DECODABLE` (or `CHECK-NOT-ENCODABLE`). The check walks the type the
  way the decodable and encodable checks do now, with one more argument that
  says whether the type is the direct type of a struct field; it reports the
  first problem it finds, at the span of the target or argument, and the message
  says where the `JsonField` sits: the struct and field (`Wrapper.items`), "list
  item", "map value", "nested JsonField", "encode argument" (the whole argument
  of `JSON.encode` or `JSON.from`), and, after 10d, "payload of `Enum.Variant`".
- **Not a generic exception for `$defs`.** §15.3 and §15.4 keep generic
  instances out of decode and schema because `$defs` is keyed by the bare type
  name. `JsonField[T]` is the one generic instance they accept: it never gets a
  `$defs` entry, since its schema is the inline `anyOf` above.
- **Generic structs (§15.3, 10c).** A field whose type is `JsonField` after
  substitution, such as `value` in `Box[JsonField[Int]]`, counts as a direct
  struct field for `JSON.encode` and `JSON.from`. Decode and schema still reject
  the generic `Box[...]` with `CHECK-NOT-DECODABLE`. The placement walk runs on
  the field types after substitution, and its `seen` list is keyed by the full
  instance type (kind, name and type arguments), not the bare struct name as
  today's walks do. So `Box[T]` with `items: List[T]`, used
  as `Box[JsonField[Int]]`, has `List[JsonField[Int]]` and is
  `CHECK-JSON-FIELD-PLACE`, and a `Box[Int]` seen earlier does not hide it.
- **Which code wins.** The placement check runs first, before the decodable and
  encodable checks, so `List[JsonField[Nil]]` in a decode target is
  `CHECK-JSON-FIELD-PLACE`, not `CHECK-NOT-DECODABLE`. A `JsonField[Nil]` in a
  good place (a direct struct field) passes the placement check and is then
  `CHECK-NOT-DECODABLE` or `CHECK-NOT-ENCODABLE`.
- **Binary serialization.** In `Term.encode` and `Term.decode` (§16),
  `JsonField[T]` is an ordinary generic enum instance (§16.3), written as the
  2-element array `[tag, values]` of §16.4: `Absent` is `["Absent", []]` and
  `Value(x)` is `["Value", [x]]`. It has no special absent-key meaning there: a
  struct field that holds `Absent` is still written under its key, and a missing
  key is an error on decode, as for any field.
- **Outside JSON** `JsonField[T]` is an ordinary enum value: locals, parameters,
  returns, lists and maps may hold it, and it is printable when `T` is
  (`JsonField.Value(30)`, `JsonField.Absent`). Like every enum it has no `==`;
  use `case`.
- **Not `Option`.** `JsonField` is only for JSON shapes. `Option` stays a free
  name, since many programs declare their own `enum Option[T]`; the open
  question of a builtin `Option[T]` (roadmap, "Later extensions") is not changed
  by this.
- **Not in this plan.** `JsonField[T]` is always optional and nullable. Separate
  "required but nullable" and "optional but not nullable" forms are not covered,
  for example for strict structured-output schemas that need every property in
  `required`. `additionalProperties: false` is also absent from `JSON.schema`
  today, and this plan does not add it.
- **Reserved name.** `JsonField` becomes a reserved type name: a user
  `struct JsonField`, `enum JsonField` or `import ... as JsonField` is
  `CHECK-REDEFINED-NAME`. This is a breaking change; say so in the changelog.
- **Builtin enum path.** `JsonField` reuses the builtin-enum path that
  `JsonValue` adds in §15.2 (10b): the checker's enum table, lowering, and the
  import linking in `compiler/` for patterns, constructors and the bare nullary
  forms `JsonField.Absent` and `JsonField.Null` (which arrive as
  `type-expression`s). It adds one thing: `JsonField` has a type parameter, so
  its table entry is generic like a user generic enum. For type references,
  adding `JsonField` to `RESERVED_TYPE_NAMES`
  (`compiler/catalog/builtins_data.agc`) is what keeps a field type like `age:
  JsonField[Int]` unchanged when linking an imported module.
- **Encode:** a `JsonField` value writes nothing for `Absent` (the key is left
  out), `null` for `Null` and `x` for `Value(x)`. Once 10d lands, encode matches
  `JsonField` before the generic tagged-enum path, since builtin enums are not
  user enums.
- **Diagnostics:** one new code, `CHECK-JSON-FIELD-PLACE`. A missing variant is
  `CHECK-NON-EXHAUSTIVE-CASE`; a wrong payload type is `CHECK-TYPE-MISMATCH`.
- **VM:** `JsonField` is a builtin entry of the enum table with the
  fixed variant order `Absent`, `Null`, `Value`, written to the Enums section
  only when a program uses it, as for `JsonValue`. Typed decode, schema and
  encode need to know that a struct field is a `JsonField[T]`: the type table
  gets an entry kind for it that points to `T`, like the List and Map entries.
  If the JSON PR's type table has no such kind, 10e adds it and bumps the
  bytecode format version (`docs/vm/03-ir-and-bytecode.md` §4); otherwise the
  layout does not change and there is no bump.
- **Tests** cover each rule above, with the placement and code-priority cases
  (including `List[JsonField[Nil]]`), a round trip, a generic `Box` once 10c
  lands, `JsonField` in an imported module, and the VM differential tests.
