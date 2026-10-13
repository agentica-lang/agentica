## 2. Design decisions

| Aspect | Rule |
|---|---|
| Syntax | `def`, `struct`, `enum`, `case`, `if`, `while`, `for`, `end`; blocks end with `end` |
| Types | Static, with local inference where it is evident |
| Calls | Parentheses are required |
| Signatures | Explicit return type and required annotations |
| Data | Variables can be reassigned; lists, maps, and structs are immutable |
| Numbers | 64-bit `Int`, no implicit conversions |
| Names | Function names may end in `?` (predicate) or `!` (halting form), independently of whitespace before `(` |
| Library | Builtin modules `Map`, `List`, `String`, `IO`, `System`, `Result`, `JSON`, `Task`, `File`, `Dir`, `Path`, `TCP` and `TLS`; `std/` modules written in Agentica, such as `std/http` |

Generic enums and exhaustive `case` matching are part of the current language. Other proposals remain in [`future/`](future/README.md).

