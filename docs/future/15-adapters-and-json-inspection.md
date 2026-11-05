## 15. JSON inspection

Planned, with no issue yet: an enum form of `JSON.kind` for JSON of unknown
shape. Calling `Fn` fields without `.call`, the JSON form of enums, generic
structs and optional JSON fields are built.

### 15.2 `JsonValue`

Open: the built `JSON.kind(j) -> String`
(`site/content/library/text-and-data/json.md`) already uses this name, so the
enum form below needs another name, or replaces it.

- `JSON.kind(j: Json) -> JsonValue`, also the method `j.kind`. It looks one
  level into a `Json` and never fails.
- `JsonValue` is a builtin enum:

  ```agentica
  enum JsonValue
    JsonNull
    JsonBool(Bool)
    JsonInt(Int)
    JsonBigInt(String)
    JsonFloat(Float)
    JsonString(String)
    JsonList(List[Json])
    JsonObject(Map[String, Json])
  end
  ```

  A walker over unknown JSON matches it with `case`, and its list arm recurses:
  `JsonValue.JsonList(items) -> for item in items ... end`.

- **Numbers** follow `JSON.int` and `JSON.float`, and `JSON.parse` does not
  change: The rule is by value, not by text:
  - `JsonInt(n)` for an exact integer that fits in a signed 64-bit `Int`. This
    is exactly when `JSON.int(j)` is `ok(n)`.
  - `JsonBigInt(text)` for any other exact integer. `text` is its decimal text,
    so it stays exact; `JSON.int` fails on it, as it does today.
  - `JsonFloat(x)` for a double, the value `JSON.float` returns.

  `JSON.parse` makes a double exactly for a number written with a fraction or
  exponent, so `3.0` and `1e2` are `JsonFloat` even when they are whole numbers;
  a number that is not finite is the existing error. Values from the builders
  and `JSON.from` follow the same rule: an `Int` is `JsonInt` and a `Float` is
  `JsonFloat`. So `kind` stays total.
- **Object order:** the keys of `JsonObject` use the same sorted order as
  `JSON.decode` into a `Map`: sorted by Unicode code point (a byte-wise compare
  of UTF-8 text gives the same order). The text order is not kept, so
  `JSON.parse` does not change. The insertion order of an object made with the
  builder (`JSON.object`) is not kept either: `kind` gives its keys sorted too.
  Text order may come later if a real program needs it; it would need an ordered
  object representation.
- It works with the existing `case`, with no grammar change; variants are
  qualified (`JsonValue.JsonInt(n)`). `JsonValue` values are for reading (`to_s`
  and `inspect` like other enums) and stay out of all four JSON type functions:
  `JSON.encode` and `JSON.from` reject it with `CHECK-NOT-ENCODABLE`,
  `JSON.decode` and `JSON.schema` with `CHECK-NOT-DECODABLE`. `JsonValue`
  becomes a reserved name (`CHECK-REDEFINED-NAME`; breaking, say so in the
  changelog).
- The recommended path is still `JSON.decode` into typed structs; `kind` is the
  low-level tool for unknown shapes (a generic pretty printer, free-form config,
  a reply whose shape depends on a field). A general `typeof` or type-pattern
  `case` is not planned: static types make the answer constant, and `Json` is
  the only dynamic value.
- Diagnostics: none new (a non-`Json` argument is `CHECK-TYPE-MISMATCH`, a
  missing variant `CHECK-NON-EXHAUSTIVE-CASE`).
- The VM Json tree already has a big-integer node kept as decimal text, which
  `kind` maps to `JsonBigInt`; `1e400` stays the existing `JSON number is not
  finite` error. The rule holds for every JSON builtin that reads the tree:
  `JSON.float` on a big integer gives the nearest float (an error when not
  finite); `JSON.encode` writes the exact decimal text; typed decode fails for
  an `Int` target and takes the float for a `Float` target when finite. `-0` is
  `JsonInt(0)`; `-0.0` is `JsonFloat(0.0)`.
