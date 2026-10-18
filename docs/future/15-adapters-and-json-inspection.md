## 15. Adapters and JSON inspection

Small language items for adapters (one interface, several backends), facades,
and JSON of unknown shape. 15.1 and 15.3 serve adapters; 15.2 reads unknown
JSON; 15.4 gives enums a JSON form, which typed decoding lacks today. Each lands
on the VM in the same PR, with the grammar, the programming
skill, the site docs and tests (row 7.6).

### 15.1 Calling `Fn` fields without `.call`

```agentica
struct Storage
  get: Fn[String, Result[String]]
  put: Fn[String, String, Result[Void]]
end

def getter(f: Fn[String, Result[String]]) -> Fn[String, Result[String]]
  return f
end

def putter(f: Fn[String, String, Result[Void]]) -> Fn[String, String, Result[Void]]
  return f
end

def valid_name?(name: String) -> Bool
  allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  return name != "" and String.split(name, "").all? do |c|
    String.contains?(allowed, c)
  end
end

def disk_storage(dir: String) -> Storage
  get = getter() do |key|
    if !valid_name?(key)
      return error("bad key")
    end
    File.read_text("#{dir}/#{key}", 1000)
  end
  put = putter() do |key, text|
    if !valid_name?(key)
      return error("bad key")
    end
    File.write_text("#{dir}/#{key}", text, 1000)
  end
  return Storage(get: get, put: put)
end

def memory_storage(items: Map[String, String]) -> Storage
  get = getter() do |key|
    Map.get(items, key)
  end
  put = putter() do |key, text|
    error("read-only")
  end
  return Storage(get: get, put: put)
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
  Code like `save_note` takes `Storage` and does not know the backend. The disk
  backend writes files under a directory and checks each key with its own copy
  of the allow-list check `valid_name?` before it builds a path (the facade's
  `valid_name?` is private to its module, so the adapter cannot call it from
  another file; it has its own copy or lives in the same module)
  (`error("bad key")` otherwise); its tests use a temporary directory. The
  memory backend is read-only: its map is fixed when it is created, `get` reads
  it, and `put` returns `error("read-only")`. A test can pass the memory backend
  to code that only reads, and the program passes the disk one. The two backends
  live in separate programs; see "Done when" in
  [§15.6 Implementation](#156-implementation-row-76) below.
  A block can only be written as the last argument of a call, so each block goes
  through a small function that returns it (`getter`, `putter` above);
  standalone lambdas are planned in [section
  25.5](25-ruby-typed-idioms.md#255-standalone-lambdas).
- **Facade pattern:** a file module that exports a few functions and hides the
  rest. It needs no new syntax:

  ```agentica
  # users.agc
  export struct User
    name: String
    age: Int
  end

  export def save_user(dir: String, user: User) -> Result[Void]
    if !valid_name?(user.name)
      return error("bad user name")
    end
    return File.write_text("#{dir}/#{user.name}.json", JSON.encode(user), 1000)
  end

  export def load_user(dir: String, name: String) -> Result[User]
    if !valid_name?(name)
      return error("bad user name")
    end
    text = try File.read_text("#{dir}/#{name}.json", 1000)
    return JSON.decode(text, User)
  end

  def valid_name?(name: String) -> Bool
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    return name != "" and String.split(name, "").all? do |c|
      String.contains?(allowed, c)
    end
  end
  ```

  Callers write `import Users from "users"` and call
  `Users.load_user(dir, "ana")`; `valid_name?` stays hidden. A facade or adapter
  must check a name with an allow-list before it uses it in a path, as
  `valid_name?` does: the name is not empty and has only ASCII letters, digits,
  `-` and `_`. Otherwise it returns `error(...)`.
- **Limit:** values are immutable and blocks capture by value, so an in-memory
  adapter cannot change its own data. A memory adapter that writes needs a new
  struct per write (its `put` returns one, for example
  `Fn[String, String, MemoryStorage]`), or, later, blocks that capture a shared
  table (§13).
- Evaluator: it resolves a struct method call to the field call in the same
  checker-filled `resolved` slot it uses for builtin methods.
- VM: no new opcode. The checker records the call as an invoke of the field
  value, so lowering emits a field read and `call-value`, as for `.call`. It
  needs `.call` on the VM (7e PR 5e).

### 15.2 `JSON.kind`

```agentica
def count_numbers(j: Json) -> Int
  total = 0
  case JSON.kind(j)
    JsonValue.JsonInt(_) -> total = 1
    JsonValue.JsonBigInt(_) -> total = 1
    JsonValue.JsonFloat(_) -> total = 1
    JsonValue.JsonList(items) ->
      for item in items
        total = total + count_numbers(item)
      end
    JsonValue.JsonObject(fields) ->
      for key in fields.keys
        total = total + count_numbers(fields[key])
      end
    _ -> total = 0
  end
  return total
end
```

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
  `JSON.decode` into a `Map`: sorted by Unicode code point (typed decode in
  `src/json-typed.rkt` sorts with `symbol<?`; a byte-wise compare of UTF-8 text
  gives the same order). The text order is not kept, so `JSON.parse` does not
  change. The insertion order of an object made with the builder (`JSON.object`)
  is not kept either: `kind` gives its keys sorted too. Text order may come
  later if a real program needs it; it would need an ordered object
  representation in the evaluator.
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
- Front end and VM: `JsonValue` is the first builtin enum, so it needs a path
  in the checker's enum table.
- Import linking (in `compiler/`): it renames each module's names and rejects
  unknown aliases, so `JsonValue` needs a path there too, like the existing
  `Result` exception (`[(and (eq? kind 'enum) (string=? name "Result")) name]`).
  It covers enum patterns and constructors (`JsonValue.JsonInt(n)`), and the
  bare nullary form `JsonValue.JsonNull`, which arrives as a `type-expression`
  and is resolved there. Without it, linking renames these names or rejects them
  with `CHECK-IMPORT-NAME`.
- Planned tests: besides `case` over every variant and the number fixtures
  below, `JsonValue` used inside an imported module (patterns, a payload
  constructor and `JsonValue.JsonNull`), checked and run through an `import`.
- VM: needs the JSON PR (`docs/vm/12-testing-and-pr-plan.md` §12.2 item 7).
  `JsonValue` is a builtin entry of the enum table with this fixed variant
  order, so `case` lowers as for user enums. Like a user enum, `JsonValue` is
  written to the bytecode Enums section only when a program uses it, so the file
  layout and the opcode meanings do not change and 10b needs no format bump. If
  the implementation ever needs a fixed index or a layout change, 10b bumps the
  format version itself (`docs/vm/03-ir-and-bytecode.md` §4). The JSON PR adds
  no placeholder for it. Numbers in the VM:
  - The VM Json tree already has a big-integer node kept as decimal text
    (`docs/vm/05-values-execution-builtins.md` §5, Json row). An integer written
    without a fraction or exponent that is outside int64 is that node, and
    `JSON.kind` maps it to `JsonBigInt` with its exact decimal text.
  - A number with a fraction or exponent is a double (`JsonFloat`). A non-finite
    one, such as `1e400`, is the existing `JSON number is not finite` error.
  - The rule holds for every JSON builtin that reads the tree, not only `kind`:
    `JSON.float` on a big integer gives the same float as the evaluator
    (`exact->inexact`, and the same error when the result is not finite);
    `JSON.encode` writes it back as its exact decimal text; typed decode treats
    it as the evaluator does (an `Int` target fails, a `Float` target takes
    `exact->inexact` of it when that is finite).
  - `-0` is read as exact 0 by the evaluator, so it is `JsonInt(0)`. `-0.0` has
    a fraction, so it is a double, but Racket's `read-json` (Racket CS 9.3)
    drops the sign and reads it as `0.0`, so it is `JsonFloat(0.0)`. The VM must
    match both.
  - Planned differential fixtures: `9223372036854775808` and
    `-9223372036854775809` (both `JsonBigInt`), `-0` (`JsonInt(0)`), `-0.0`
    (`JsonFloat(0.0)`) and `1e400` (the error).

  `JSON.kind` is a builtin that builds the variant from the parsed node; lists
  and maps hold the child nodes as `Json` values without copying them.

### 15.3 Generic structs

```agentica
struct Box[T]
  value: T
end

struct Cache[V]
  items: Map[String, V]
  limit: Int
end

def main() -> Void
  b = Box(value: 1)                                 # Box[Int]
  puts(b.value + 1)                                 # b.value is Int
  c: Cache[Int] = Cache(items: {}, limit: 10)
end
```

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
  linking (in `compiler/`) must carry the type parameters through: today its
  `struct-decl` case rewrites every field type through `resolve`, so a bare `T`
  would get the module prefix. It needs the same check as `rewrite-enum-type`
  does for enums (a parameter name with no type arguments stays as it is).
  Planned test: a generic struct declared in an imported module and used as
  `M.Box[Int]`.
- Diagnostics reuse the enum codes: a wrong number of type arguments, or a bare
  `Box` in a type, is `CHECK-UNKNOWN-TYPE`; a repeated or reserved parameter
  name is `CHECK-REDEFINED-NAME`; a parameter that cannot be inferred is
  `CHECK-ENUM-TYPE-INFERENCE` (the message names the struct); conflicting field
  types are `CHECK-TYPE-MISMATCH`.
- `CHECK-ENUM-TYPE-INFERENCE` is reused for structs and keeps its name; 10c adds
  a note about it to the diagnostics reference of the programming skill.
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
- VM: lands with or after the JSON PR (`docs/vm/12-testing-and-pr-plan.md` §12.2
  item 7); the type table gets an enum entry with each variant's payload types.
  If the JSON PR's type table has no enum entry kind, 10d adds it and bumps the
  format version (`docs/vm/03-ir-and-bytecode.md` §4); the JSON PR adds no
  placeholder for it.

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

- One PR per item (10a–10e), each with its own tests and docs. 10a needs
  `.call` on the VM (done); 10b, 10d and 10e, and the JSON part of 10c,
  need the VM JSON work; 10e also needs 10b. The VM check and the disk
  example are two separate programs.
- 10a `Fn` fields without `.call` (§15.1); 10b `JSON.kind` with the
  `JsonValue` enum (§15.2); 10c generic structs (§15.3); 10d JSON for
  enums (§15.4); 10e optional and nullable JSON fields (§17).
- Done when: two programs run. The VM program has a `Storage` adapter
  with a read-only memory backend and a walker over unknown JSON, using
  only builtin library calls (golden check). The disk program uses the
  same `Storage` shape with a disk backend whose `get` and `put` check
  each key with an allow-list (`error("bad key")` otherwise, e.g.
  `../x`), in a temporary directory passed as an argument.

