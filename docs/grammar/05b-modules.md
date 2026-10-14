### File modules and imports

Each file is a module. `import "models" as Models` loads `models.agc`, and `import "../lib/util" as Util` loads `../lib/util.agc`. The path has no extension. A path ending in `.agc`, an empty path, a path ending in `/`, or a last part containing a dot (`"models.rb"`, `"."`, `".."`) is `CHECK-IMPORT-PATH`, so a module file name has no dot apart from `.agc`: `json.tools.agc` cannot be imported; rename it `json_tools.agc`.

Relative paths resolve from the importing file, not the working directory. Each file is linked once. Cycles are `CHECK-IMPORT-CYCLE`, missing or unreadable files are `CHECK-IMPORT-IO`, and invalid paths are `CHECK-IMPORT-PATH`; each is located at the import.

Only `export struct`, `export enum` and `export def` are visible outside the file. Use `Models.User` in annotations and JSON type arguments, `Models.User(name: "Ana")` to construct, `Models.greet(user)` to call, `&Models.greet` for a function value, `Models.Option[T]` as an enum type, and `Models.Option.Some(value)` for a variant. Local names stay unqualified. Import aliases are uppercase and cannot collide with declarations, other aliases or builtin names. Imports cannot be re-exported. Exported signatures may mention private types, but importers cannot name or construct them.

Only the root file supplies the executable `main() -> Void`; imported `main` functions do not run. Imported calls and tasks share the program's step budget and resource ownership. The CLI and `agentica test` use the same loader. There are no wildcard imports, package registry, module state, nested modules or receiver attachment. `as` is contextual in imports, not reserved.

#### Standard library and external libraries

- `import "std/queue" as Queue` loads the standard library embedded at build time. Nothing needs to be installed, and local files or external roots cannot shadow it. Embedded modules may use relative imports inside `std/`.
- `import "pkg/acme/tools" as Tools` searches for `acme/tools.agc` in order: `agc_libs/` beside the root program (not beside a dependency); the absolute roots in `AGENTICA_PATH` (`:`-separated, `;` on Windows), in order; `$XDG_DATA_HOME/agentica/lib/` (default `~/.local/share/agentica/lib/`; on Windows `%LOCALAPPDATA%/agentica/lib/`); then `/usr/local/share/agentica/lib/` and `/usr/share/agentica/lib/` (none on Windows).

The first existing file wins, and an error in that file does not fall back to another root. Empty `AGENTICA_PATH` entries are ignored; a relative entry is `CHECK-IMPORT-PATH`. Library paths use forward slashes and reject empty, `.`, `..`, backslash and colon components. After symlink resolution, the target must stay inside its root. These checks apply to namespaced imports only: imports are not a filesystem sandbox. A missing module is `CHECK-IMPORT-IO`. Diagnostics inside an embedded module name its source, such as `std/queue.agc`.

#### String queue (`std/queue`)

`std/queue` is written in Agentica; its signatures are in [`library/data-structures/queue.md`](../../site/content/library/data-structures/queue.md). Push adds at the back and pop removes the oldest value. Pop and peek on an empty queue return an error Result. Inputs are never changed: continue with the returned queue or `Popped.remaining`. Empty strings and duplicates are valid. There are no user generics and no blocking cross-task operations. `push`, `pop`, `peek`, `size` and `empty?` are O(n) with the current list operations; no constant-time FIFO is promised.

#### BDD steps (`std/bdd`)

`std/bdd` is the step API of `agentica test`, written in Agentica. Most `BDD.*` functions take the context first and return it; see [`library/testing/bdd.md`](../../site/content/library/testing/bdd.md) and [`bdd.md`](../bdd.md). `BDD.Context` can be named but not built: a context exists only inside a step, so use the context that a call returns. The modules `std/bdd/gherkin`, `std/bdd/match`, `std/test/report` and `std/test/runner` are internal to `agentica test` and unsupported.
