### File modules and imports

Each file is a module. `import "models" as Models` loads `models.agc`, and `import "../lib/util" as Util` loads `../lib/util.agc`. The path has no extension. A path ending in `.agc`, an empty path, a path ending in `/`, or a last part containing a dot (`"models.rb"`, `"."`, `".."`) is `CHECK-IMPORT-PATH`, so a module file name has no dot apart from `.agc`: `json.tools.agc` cannot be imported; rename it `json_tools.agc`.

Relative paths resolve from the importing file, not the working directory. Each file is linked once. Cycles are `CHECK-IMPORT-CYCLE`, missing or unreadable files are `CHECK-IMPORT-IO`, and invalid paths are `CHECK-IMPORT-PATH`; each is located at the import.

Only `export struct`, `export enum` and `export def` are visible outside the file. Use `Models.User` in annotations and JSON type arguments, `Models.User(name: "Ana")` to construct, `Models.greet(user)` to call, `&Models.greet` for a function value, `Models.Option[T]` as an enum type, and `Models.Option.Some(value)` for a variant. Local names stay unqualified. Import aliases are uppercase and cannot collide with declarations, other aliases or builtin names. Imports cannot be re-exported. Exported signatures may mention private types, but importers cannot name or construct them.

Every file keeps the declaration order of section 5: imports, then types, then `export def`, then private `def`. An imported file out of order is `CHECK-DECL-ORDER`, located in that file.

Only the root file supplies the executable `main() -> Void`; imported `main` functions do not run. Imported calls and tasks share the program's step budget and resource ownership. The CLI and `agentica test` use the same loader. There are no wildcard imports, package registry, module state, nested modules or receiver attachment. `as` is contextual in imports, not reserved.

#### Standard library and external libraries

- `import "std/queue" as Queue` loads the standard library embedded at build time. Nothing needs to be installed, and local files or external roots cannot shadow it. Embedded modules may use relative imports inside `std/`.
- `import "pkg/acme/tools" as Tools` searches for `acme/tools.agc` in order: `agc_libs/` beside the root program (not beside a dependency); the absolute roots in `AGENTICA_PATH` (`:`-separated, `;` on Windows), in order; `$XDG_DATA_HOME/agentica/lib/` (default `~/.local/share/agentica/lib/`; on Windows `%LOCALAPPDATA%/agentica/lib/`); then `/usr/local/share/agentica/lib/` and `/usr/share/agentica/lib/` (none on Windows).

The first existing file wins, and an error in that file does not fall back to another root. Empty `AGENTICA_PATH` entries are ignored; a relative entry is `CHECK-IMPORT-PATH`. Library paths use forward slashes and reject empty, `.`, `..`, backslash and colon components. After symlink resolution, the target must stay inside its root. These checks apply to namespaced imports only: imports are not a filesystem sandbox. A missing module is `CHECK-IMPORT-IO`. Diagnostics inside an embedded module name its source, such as `std/queue.agc`.

#### String queue (`std/queue`)

`std/queue` is written in Agentica; its signatures are in [`library/data-structures/queue.md`](../../site/content/library/data-structures/queue.md). Push adds at the back and pop removes the oldest value. Pop and peek on an empty queue return an error Result. Inputs are never changed: continue with the returned queue or `Popped.remaining`. Empty strings and duplicates are valid. There are no user generics and no blocking cross-task operations. `push`, `pop`, `peek`, `size` and `empty?` are O(n) with the current list operations; no constant-time FIFO is promised.

#### Binary data (`std/binary`)

`std/binary` reads and writes binary numbers in a `List[Int]` of bytes, each item in `0 .. 255`, the list that `IO.read_bytes`, `File.read_bytes` and the other `*_bytes` builtins use. It is written in Agentica on the `Int` and `Float` bit builtins; its signatures are in [`library/text-and-data/binary.md`](../../site/content/library/text-and-data/binary.md). With the alias `Binary`:

- `Binary.read_u8`, `read_i8`, and `read_{u16,i16,u32,i32,u64,i64}_{be,le}` take `(data: List[Int], offset: Int)` and return `Result[Int]`. `Binary.read_f32_{be,le}` and `read_f64_{be,le}` return `Result[Float]`. `_be` is big-endian (network order), `_le` is little-endian, and signed types use two's complement. A reader never halts: a bad `offset`, a non-byte item, or a `u64` with the top bit set is an `error(...)`. The `offset` is zero-based and may be any `Int`.
- `Binary.write_u8`, `write_i8`, and `write_{u16,i16,u32,i32,u64}_{be,le}` take a value and return `Result[List[Int]]`, an error when the value is outside the type's range. `Binary.write_i64_{be,le}`, `write_f32_{be,le}` and `write_f64_{be,le}` cannot fail and return a plain `List[Int]`. `write_f32_*` rounds to binary32; every NaN is written as the canonical NaN (`Float.to_bits`, `Float.to_bits32`).
- `Binary.concat(parts: List[List[Int]]) -> List[Int]` joins any number of parts in order, in O(n log k) for n bytes in k parts. `Binary.frame(payload: List[Int]) -> Result[List[Int]]` puts the payload's 4-byte big-endian length in front of it (an error above `4294967295` items). `Binary.read_frame_length(data, offset, max) -> Result[Int]` reads that length and returns an error above `max`, so a reader can reject a hostile length before it reads the body.
- `Int` is signed, so a `u64` above `9223372036854775807` is not an `Int`: `read_u64_*` returns an error for it and `write_u64_*` rejects a negative value. Use `read_i64_*` and `write_i64_*` for all 64 bits. Every `ok` of an integer reader writes back to the same bytes; a float reader does too, except that a NaN pattern other than the canonical one comes back canonical.
- Errors are checked in this order and the first that applies is returned: a negative `max` (`read_frame_length` only), an `offset` below zero or above `data.size - n`, the first item by index that is not a byte, the `u64` top bit, a writer's value outside its type, a payload over `4294967295` items, a frame length above `max`. Messages are lowercase with no final period: `u32 at offset 10 is outside a list of length 12`, `value 300 at index 2 is not a byte`, `u64 at offset 0 does not fit in Int`, `value 70000 does not fit in u16`, `payload of 4294967296 bytes does not fit in a u32 length`, `frame length 70000 is above the limit 65536`, `frame limit -1 is negative`.
- Writers return new lists and no buffer is ever changed. Offset writers into an existing list and the compact `Bytes` type are not part of the module.

#### BDD steps (`std/bdd`)

`std/bdd` is the step API of `agentica test`, written in Agentica. Most `BDD.*` functions take the context first and return it; see [`library/testing/bdd.md`](../../site/content/library/testing/bdd.md) and [`bdd.md`](../bdd.md). `BDD.Context` can be named but not built: a context exists only inside a step, so use the context that a call returns. The modules `std/bdd/gherkin`, `std/bdd/match`, `std/test/report` and `std/test/runner` are internal to `agentica test` and unsupported.
