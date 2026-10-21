## 4. Standard library and function values (phases 5f2–5m)

Mostly built. The normative grammar is `grammar.md` and the programming
reference (function values, typed JSON, builders/schema, file imports and
exports); remaining extensions stay planned (§3). The rules below are not stated
there as such.

- **`&name` and `.call(...)`:** `&name` turns a top-level function into a value
  of type `Fn[...]`, and `value.call(args)` calls it. `call` is not a reserved
  word: it has this meaning only right after a `.` and before `(`. There are no
  closures: `&name` does not capture variables. The checker requires `name` to
  be a declared function and compares parameters and return type with the
  expected type. Precedence 1, like the named call.
- **Bare type names:** core JSON.decode/schema arguments include imported types
  such as Models.User. Types are not runtime values.
- Opaque handles have no constructor or fields; inspect prints a type marker.

Programs the checker must reject:

```ruby
x = User               # A type is valid only as an argument of JSON.decode or JSON.schema.
f = &missing           # &name requires a declared function.
ready = done?          # A function name is not a value; use &done?.
```
