## 15. Adapters and JSON inspection

Small language items for adapters (one interface, several backends), facades,
and JSON of unknown shape. 15.1 and 15.3 serve adapters; 15.2 reads unknown
JSON; 15.4 gives enums a JSON form, which typed decoding lacks today.

### 15.1 Calling `Fn` fields without `.call`

```agentica
struct Storage
  get: Fn[String, Result[String]]
  put: Fn[String, String, Result[Void]]
end

def save_note(store: Storage, name: String, text: String) -> Result[Void]
  return store.put(name, text)   # today: store.put.call(name, text)
end
```

- If `s` is a struct and its field `put` has type `Fn[...]`, then `s.put(a, b)`
  calls it. It means the same as `s.put.call(a, b)`. It also works on a nested
  field (`app.store.put(a, b)`) and with no arguments (`s.reset()`).
- `s.put` without parentheses is still the field value, so it can be passed on
  or stored.
- A block is allowed: `s.put(a) do |x| ... end` passes the block as the last
  argument, the same as `s.put.call(a) do |x| ... end`.
- A block without parentheses is a call too: `s.run do |x| ... end`, where `run`
  is a `Fn` field, calls it with the block as its only argument, like
  `xs.each do ... end`. A bare `s.run` with no block and no parentheses is still
  the field value. In `case`, `while` and `for` headers a `do` belongs to the
  header and is never a block (as `grammar.md` says), so `for x in s.gen do`
  reads the field `s.gen`; write `(s.gen do ... end)` to call it.
- Structs have no user methods, so there is no ambiguity with them. Methods on
  user types were decided against ([section
  25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c)), so this
  precedence question does not arise. Section 25.3 bans `Fn` fields named
  `with`, so `value.with(...)` stays the struct update. The only methods a
  struct has today are the builtin `to_s` and `inspect` of printable structs.
  Today `s.to_s` without parentheses reads a field named `to_s` if there is one,
  but `s.to_s()` with parentheses goes to method checking and calls the builtin.
  The new rule only adds a case: `s.name(...)` calls the field when `name` is a
  `Fn` field. A `Fn` field named `to_s` or `inspect` cannot clash with the
  builtin, because a struct with a `Fn` field has no `to_s` or `inspect` either,
  because a `Fn` is not printable. Today `s.put(a, b)` is `CHECK-UNKNOWN-METHOD`
  (with the help "put is a function field; call it with .put.call(...)"), so no
  valid program changes meaning.
- On a generic struct (15.3) the rule applies after substitution: for
  `b: Box[Fn[Int, Int]]`, `b.value(1)` calls the field.
- Arity and type errors are the same as for `.call`: a wrong number of arguments
  is `CHECK-ARITY`, a wrong argument type is `CHECK-TYPE-MISMATCH`. A name that
  is not a field, or a field that is not a `Fn`, stays `CHECK-UNKNOWN-METHOD`
  with today's help.
- **Adapter pattern:** a struct of `Fn` fields is the interface; a function such
  as `disk_storage(dir)` is one implementation, and its blocks capture `dir`.
  Code like `save_note` takes `Storage` and does not know the backend. A disk
  backend checks each key with an allow-list before it builds a path
  (`error("bad key")` otherwise); a private `valid_name?` of another module
  cannot be called, so the adapter has its own copy or lives in the same module.
  A memory backend can be read-only (`put` returns `error("read-only")`), so a
  test passes it to code that only reads. A block can only be written as the
  last argument of a call, so each block goes through a small function that
  returns it (for example `getter(f)` returning its `Fn` argument); standalone
  lambdas are planned in [section
  25.5](25-ruby-typed-idioms.md#255-standalone-lambdas).
- **Facade pattern:** a file module that exports a few functions and hides the
  rest (for example `export def save_user` and `load_user` over a private
  `valid_name?`). It needs no new syntax. Callers write
  `import Users from "users"` and call `Users.load_user(dir, "ana")`. A facade
  or adapter must check a name with an allow-list before it uses it in a path:
  the name is not empty and has only ASCII letters, digits, `-` and `_`.
  Otherwise it returns `error(...)`.
- **Limit:** values are immutable and blocks capture by value, so an in-memory
  adapter cannot change its own data. A memory adapter that writes needs a new
  struct per write (its `put` returns one, for example
  `Fn[String, String, MemoryStorage]`), or, later, blocks that capture a shared
  table (§13).
- Compiler only, no new opcode: the checker records the call as an invoke of the
  field value, so lowering emits a field read and a call of the value, as for
  `.call`.

### 15.2 `JSON.kind`

Open: the built `JSON.kind(j) -> String` (`docs/grammar/06b-builtins.md`)
already uses this name, so the enum form below needs another name, or replaces
it.

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
- It works with the existing `case`, the branch check and bindings, with no
  grammar change. Variants are qualified like any enum (`JsonValue.JsonInt(n)`).
  `JsonValue` values are for reading: they have `to_s` and `inspect` like other
  enums. `JsonValue` stays out of all four JSON type functions: `JSON.encode`
  and `JSON.from` reject it with `CHECK-NOT-ENCODABLE`, and `JSON.decode` and
  `JSON.schema` with `CHECK-NOT-DECODABLE`; build Json with the builders, and
  use `Json` for free-form data.
- `JsonValue` becomes a reserved name: a user `struct JsonValue`,
  `enum JsonValue` or `import ... as JsonValue` is `CHECK-REDEFINED-NAME`. This
  is a breaking change; say so in the changelog.
- The recommended path is still `JSON.decode` into typed structs. `kind` is the
  low-level tool for unknown shapes: a generic pretty printer, a config with
  free-form values, or a reply whose shape depends on a field.
- Unlike Ruby's `case x when String`, a general `typeof` or a type-pattern
  `case` is not planned. Static types make the answer constant for every other
  value; `Json` is the only dynamic value, and `kind` covers it.
- Diagnostics: none new. A non-`Json` argument is `CHECK-TYPE-MISMATCH`; a
  missing variant is `CHECK-NON-EXHAUSTIVE-CASE`.
- Front end: `JsonValue` is the first builtin enum, so the checker's enum table
  and the import linking (`compiler/modules`, which renames each module's names
  and rejects unknown aliases) need a path for it, like the existing `Result`
  exception. It covers enum patterns and constructors (`JsonValue.JsonInt(n)`)
  and the bare nullary form `JsonValue.JsonNull`, which arrives as a
  `type-expression`. Without it, linking renames these names or rejects them
  with `CHECK-IMPORT-NAME`.
- VM: `JsonValue` is a builtin entry of the enum table with this fixed variant
  order, so `case` lowers as for user enums. Like a user enum, it is written to
  the bytecode Enums section only when a program uses it, so the file layout and
  the opcode meanings do not change; if a fixed index or a layout change is ever
  needed, 10b bumps the format version itself (`docs/vm/03-ir-and-bytecode.md`
  §4). Numbers in the VM:
  - The VM Json tree already has a big-integer node kept as decimal text
    (`docs/vm/05-values-execution-builtins.md` §5, Json row). An integer written
    without a fraction or exponent that is outside int64 is that node, and
    `JSON.kind` maps it to `JsonBigInt` with its exact decimal text
    (`9223372036854775808` and `-9223372036854775809` are `JsonBigInt`).
  - A number with a fraction or exponent is a double (`JsonFloat`). A non-finite
    one, such as `1e400`, is the existing `JSON number is not finite` error.
  - The rule holds for every JSON builtin that reads the tree, not only `kind`:
    `JSON.float` on a big integer gives the nearest float (an error when the
    result is not finite); `JSON.encode` writes it back as its exact decimal
    text; typed decode fails for an `Int` target and, for a `Float` target,
    takes the float of it when that is finite.
  - `-0` is read as exact 0, so it is `JsonInt(0)`. `-0.0` has a fraction, so it
    is a double, but its sign is dropped: `JsonFloat(0.0)`.

  `JSON.kind` is a builtin that builds the variant from the parsed node; lists
  and maps hold the child nodes as `Json` values without copying them.

### 15.3 Generic structs

- Same rules as generic enums: `struct Name[T, ...]` declares type parameters;
  their names may not repeat or reuse a reserved type name. Construction infers
  them from the field values; when it cannot (an empty list or map), it needs an
  expected type from an annotation, parameter, field or return. Type arguments
  are checked like enum type arguments.
- A field named `with` whose type is a type parameter is `CHECK-REDEFINED-NAME`
  at the declaration, since the parameter could be an `Fn`, and
  `value.with(...)` is the struct update of
  [`docs/grammar/06-semantics.md`](../grammar/06-semantics.md#structs-and-lists)
  (which already bans `Fn` fields named `with`).
- `Map` keys must still be `Int` or `String`. A type parameter used as a `Map`
  key (`items: Map[K, V]`) is rejected at the declaration with
  `CHECK-MAP-KEY-TYPE`, as for generic enums today.
- All rules apply after substitution. Field access returns the substituted type:
  `b.value` is `Int` for a `Box[Int]`. `data-type?` is checked on the
  substituted type, so `Box[Int]` has `to_s` and `inspect`, and
  `Box[Fn[Int, Int]]` does not.
- An imported generic struct is written `M.Box[Int]`, as for enums. Import
  linking (in `compiler/`) must carry the type parameters through: a bare `T` in
  a field type must not get the module prefix, as for enums (a parameter name
  with no type arguments stays as it is).
- Diagnostics reuse the enum codes: a wrong number of type arguments, or a bare
  `Box` in a type, is `CHECK-UNKNOWN-TYPE`; a repeated or reserved parameter
  name is `CHECK-REDEFINED-NAME`; a parameter that cannot be inferred is
  `CHECK-ENUM-TYPE-INFERENCE` (the message names the struct); conflicting field
  types are `CHECK-TYPE-MISMATCH`.
- `CHECK-ENUM-TYPE-INFERENCE` is reused for structs and keeps its name.
- They enable a reusable adapter: `struct Storage[T]` with
  `get: Fn[String, Result[T]]` and `put: Fn[String, T, Result[Void]]`, filled
  once per backend.
- JSON: `JSON.encode` and `JSON.from` work on any generic instance, struct or
  enum (with 15.4), whose fields or payloads are encodable after substitution,
  because encoding needs no `$defs`. Only `JSON.decode` and `JSON.schema` reject
  a generic instance, struct or enum, anywhere in the target, with
  `CHECK-NOT-DECODABLE` (except `JsonField[T]` as a direct struct field, §17),
  until a real program needs it. The reason: `$defs` is keyed by the bare type
  name, so `Box[Int]` and `Box[String]` would collide. A direct target would
  also need type arguments in expression position (`Box[Int]` reads as
  indexing). A bare generic target with no type arguments, such as
  `JSON.decode(text, Box)` or `JSON.schema(Option)`, is `CHECK-UNKNOWN-TYPE`, as
  type resolution gives today.
- VM: no change. Type parameters exist only in the checker, as for generic
  enums; the struct table keeps field names and order.

### 15.4 JSON for enums

Today `JSON.decode` and `JSON.schema` take named structs only, and a struct with
an enum field is `CHECK-NOT-DECODABLE`; `JSON.encode` rejects enums too
(`CHECK-NOT-ENCODABLE`). Enums are the way to model "one of these shapes", so
they need a JSON form. It uses tagged objects:

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

struct Drawing
  shapes: List[Shape]
end
```

```json
{"shapes": [{"tag": "Circle", "values": [2.0]}, {"tag": "Empty", "values": []}]}
```

- A variant is an object with `tag` (the variant name, without the enum name)
  and `values` (the payloads in order). `JSON.encode` and `JSON.from` always
  write both keys; `JSON.encode` text puts `tag` first. `JSON.decode` accepts a
  missing `values` for a nullary variant and ignores extra keys, as for structs.
- `JSON.encode` and `JSON.from` work on any user enum (not `JsonValue`) whose
  payloads are encodable, generic instances included (`Option[Int]`), because
  encoding needs no `$defs`.
- Only non-generic enums are decodable, and only when their payload types are. A
  generic enum instance such as `Option[Int]` anywhere in a decode or schema
  target is `CHECK-NOT-DECODABLE` (except `JsonField[T]` as a direct struct
  field, §17; 15.3 gives the reason); a bare `Option` is `CHECK-UNKNOWN-TYPE`.
  `Result` stays out. `JsonValue` stays out of all four functions (15.2).
- The decode target may be a non-generic enum: `JSON.decode(text, Shape)`.
- Errors return `error(...)` with the same paths as struct fields
  (`shapes[0].values[1]`): an unknown tag, a missing `tag`, a wrong number of
  values, or a wrong value type. No new code: an enum with a non-decodable
  payload is `CHECK-NOT-DECODABLE`.
- `JSON.schema(Shape)` accepts the same enums as decode and describes the
  tagged-object form. It writes a `oneOf` with one object per variant and its
  `tag` as a one-value `enum` (`{"enum": ["Rect"]}`), which also works in
  draft-04. The schema is accepted by every draft; per-payload types are checked
  from 2020-12 (`prefixItems`):
  - `values` is an array whose length is fixed with `minItems` and `maxItems`
    (the number of payloads).
  - `prefixItems`, with one schema per payload, is added only when the variant
    has payloads. There is no `"items": false`.
  - A nullary variant gets `"values": {"type": "array", "maxItems": 0}`, and
    `values` is not in its `required`, since decode accepts a missing `values`.
  - Enums go into `$defs` like structs. The root gets no `$schema`; that stays
    as today.

  For `Shape`, the `Rect` and `Empty` entries of the `oneOf`:

  ```json
  {"type": "object",
   "properties": {"tag": {"enum": ["Rect"]},
                  "values": {"type": "array", "minItems": 2, "maxItems": 2,
                             "prefixItems": [{"type": "number"}, {"type": "number"}]}},
   "required": ["tag", "values"]}
  {"type": "object",
   "properties": {"tag": {"enum": ["Empty"]},
                  "values": {"type": "array", "maxItems": 0}},
   "required": ["tag"]}
  ```
- VM: the type table gets an enum entry with each variant's payload types. If
  the type table has no enum entry kind, 10d adds it and bumps the format
  version (`docs/vm/03-ir-and-bytecode.md` §4).

### 15.5 Not planned

Structural interfaces (Go-style, where a type fits because it has the right
methods) are not planned: user types have no methods, §6 already rules out
interfaces and traits, and a struct of `Fn` fields (15.1) is an interface
checked by name. `respond_to?` is not planned: the checker knows every field and
method of a value, so the answer is constant, and a run-time check would only
hide a type error. Reflection (listing a struct's fields, building a value from
a type name, calling a function by a name in a string) is not planned: it breaks
static checking and makes the VM keep names and types at run time; use
`JSON.from` to see a value's fields and a `Map[String, Fn[...]]` to dispatch by
name.

### 15.6 Implementation (row 7.6)

- One PR per item (10a–10e), each with its own tests and docs. 10b, 10d and
  10e, and the JSON part of 10c, need the VM JSON work; 10e also needs 10b.
- 10a `Fn` fields without `.call` (§15.1); 10b `JSON.kind` with the
  `JsonValue` enum (§15.2); 10c generic structs (§15.3); 10d JSON for
  enums (§15.4); 10e optional and nullable JSON fields (§17).
- Done when: two programs run. The VM program has a `Storage` adapter with a
  read-only memory backend and a walker over unknown JSON, using only builtin
  library calls (golden check). The disk program uses the same `Storage` shape
  with a disk backend whose `get` and `put` check each key with an allow-list
  (`error("bad key")` otherwise, e.g. `../x`), in a temporary directory passed
  as an argument.
