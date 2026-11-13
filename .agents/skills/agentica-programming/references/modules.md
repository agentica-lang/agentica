# File modules and imports

Each file is a module. `import Models from "models"` loads `models.agc` and
names it `Models`; `import Util from "../lib/util"` loads `../lib/util.agc`.
Paths never include the extension (`import "models.agc"` is
`CHECK-IMPORT-PATH`, and so are an empty path, a path ending in `/`, or a last
part with a dot such as `"models.rb"`): a module file name has no dot except
`.agc` (`json.tools.agc` cannot be imported).

- Relative paths resolve from the importing file, not the working directory.
- Every file, imported ones included, keeps the order: `import`s; the public
  part (constants and re-exports, `struct`, `enum`, `type` and `module` blocks,
  `def`); `private`; the private part (constants, types and blocks, `def`). An
  imported file out of order is `CHECK-DECL-ORDER`, located in that file.
- Each file is linked once. A cycle is `CHECK-IMPORT-CYCLE`; a missing or
  unreadable import `CHECK-IMPORT-IO`; an invalid path `CHECK-IMPORT-PATH`.
- An import alias that the file never uses is `CHECK-UNUSED-IMPORT`: remove
  the import. A use is any `Alias.name` or a re-export; a regex literal uses the
  `std/regex` import and a `<<~EAG` template the `std/eag` one. An alias with no
  member (`u: User`) is `CHECK-IMPORT-NAME`. Unused names of `import {a, b}` are
  fine.

## Public and private names

A declaration is public unless it comes after a `private` line, alone on its
line: every declaration above it (constant, struct, enum, type alias, function,
module block) is public, every one after it is private to the file, and a file
with no `private` is public as a whole. Write the API first:

```agentica
LIMIT = 10

def open(id: Int) -> Int = connect(id)

private

BUFFER = 4096

def connect(id: Int) -> Int = id + BUFFER
```

- One `private` per file or block (a second is `PARSE-SECOND-PRIVATE`), with a
  blank line before and after it. Imports are never public.
- `export` before a declaration (`export def`, `export struct`, `export NAME =
  ...`) is `PARSE-UNEXPECTED-TOKEN`; `export` only re-exports (below).
- A public signature may mention private types, but importers cannot name or
  build them.
- Reaching a private name is `CHECK-IMPORT-NAME`; its help says where to move it
  (above `private`), or which `export Alias.name` would pass on a name the
  module only imports.

- Through the alias: `Models.User` in annotations and JSON type arguments,
  `Models.User(name: "Ana")` to construct, `Models.greet(user)` to call,
  `&Models.greet` for a callback; imported enums: `Models.Change[T]`,
  `Models.Change.Added(value)`, and `Models.Change.Added(item)` in a pattern.
  Local names stay unqualified inside their own file.
- Re-export: `export Url.parse` or `export Url.Address` (after the imports and
  above `private`, `Url` an alias of this file) passes on a name of an imported
  module, so a facade file collects an API. The importer gets the original
  declaration (`Web.Address` and `Url.Address` are one type, `&Web.parse` is
  `&Url.parse`); the file adds no local name. No `as`, no wildcard. An unknown
  alias or name is `CHECK-IMPORT-NAME`; a name that is also a declaration,
  re-export or alias of the file is `CHECK-REDEFINED-NAME`, so the alias must
  differ from the names it re-exports: `import V from "value"` with `export
  V.Value`, not `import Value ...` with `export Value.Value`.
- Alias names are uppercase and cannot collide with declarations, other aliases,
  imported names or builtin names.

## Private fields

A `private` line in a struct body (blank line before and after) makes the
fields after it private to the declaring module: its file (the file's
`module` blocks included), or the `module` block it is in. Use it to keep a handle or a counter inside, reached only through the
module's functions:

```agentica
struct Conn
  id: Int

  private

  socket: Int
end

def open(id: Int) -> Conn = Conn(id: id, socket: 3)

def socket_of(conn: Conn) -> Int = conn.socket
```

- Outside the module, reading, giving or setting (`with`) a private field is
  `CHECK-PRIVATE-FIELD`, and so is building the struct at all (even when the
  private fields have defaults), `T.members`, `T.codec` and JSON
  encoding or decoding of a type that holds it. Inside, all of them work.
- The value can still be passed, stored, sent, compared (`==` sees every
  field) and printed (`inspect`, `to_s` and interpolation show every field).
- `agentica doc`, `outline` and `help` list the public fields and a line "and
  private fields".

## Importing names

`import {User, greet} from "models"` brings exported names in, used bare:
`User` as a type, `User(name: "Ana")`, `greet(user)`, `user |> greet()`,
`&greet`, and for an enum `Change` the type `Change[T]`, `Change.Added(value)`
and `Change.Added(item)` in a pattern. Variants are not imported alone: import
the enum. A bare function still needs parentheses.

- An entry may rename: `import {greet as hello, User as Account} from
  "models"`. The new name keeps the case rule of what it names (a struct or enum
  capitalized, a function lowercase), else `CHECK-IMPORT-RENAME`. The original
  name is not bound by a rename.
- The list may span lines, end with a comma, and may not be empty.
- One line does one thing: `import Models, {User} from "models"` is a parse
  error; write two lines (the file loads once). A module imported only by names
  has no alias, so `Models.` is unavailable for it.
- An imported name joins the file's names. It cannot equal a declaration, an
  alias, another imported name (the same name twice too), a builtin function
  (`puts`, `ok`) or a reserved type (`Int`, `JSON`):
  `CHECK-REDEFINED-NAME` at the name (at the new name of a rename).
- A name the module does not export, or keeps private, is `CHECK-IMPORT-NAME` at
  the name in the braces, with a `did you mean` help; it is reported at the
  import, before any use.

## Constants

A public constant (`LIMIT = 100` above `private`) is shared; `import {LIMIT,
TABLE as LOOKUP} from "limits"` brings it in by name, read bare. A constant can
be renamed only to another constant name (capitals and underscores): `{LIMIT as
max}` is `CHECK-IMPORT-RENAME`. An alias reads it too: `Limits.LIMIT`,
`Limits.TABLE.size`, `Limits.CONFIG.with(port: 81)`; a private one is
`CHECK-IMPORT-NAME`, `Limits.LIMIT()` is `CHECK-TYPE-MISMATCH`. An imported
constant cannot equal a constant or another name of the file
(`CHECK-REDEFINED-NAME`); a private constant cannot be imported
(`CHECK-IMPORT-NAME`). The constants of the imported files that the program can
reach are built before `main`.

## Module blocks

`module Counter ... end` at the top level groups declarations under a name, so
one file holds several modules (a namespace only). Inside: constants, structs,
enums, aliases and functions with the file's layout rules, and its own `private`
line: what is above it is visible outside as `Counter.start(0)`,
`Counter.Msg.Add(5)`, `Counter.LIMIT`. A private name is `CHECK-IMPORT-NAME`.
The body sees the file's imports, top-level names (private too) and other
blocks; it may not declare one of those names again (`CHECK-SHADOWED-NAME`) or
`main` (`CHECK-MAIN`), but two blocks may both have `start`. A block above the
file's `private` is importable: `import {Counter} from "agents"` (an alias) or
`Agents.Counter.start(0)`. The name follows the alias rules
(`CHECK-REDEFINED-NAME`); a block inside a block is `PARSE-NESTED-MODULE`; no
import, re-export or extern block inside.

## Standard library and external libraries

- `import Queue from "std/queue"` loads the standard library embedded at build
  time: no installation, variable or checkout is needed, and local files and
  external roots cannot shadow it.
- `import Tools from "pkg/acme/tools"` is a package declared in
  `agentica.toml` (`packages.md`), else the file `acme/tools.agc`, searched in
  order:
  1. `agc_libs/` beside the root program (not beside each dependency, not the
     working directory), or beside `agentica.toml` when the project has one;
  2. absolute roots in `AGENTICA_PATH`, in order;
  3. `$XDG_DATA_HOME/agentica/lib/`, default `~/.local/share/agentica/lib/`;
  4. `/usr/local/share/agentica/lib/`, then `/usr/share/agentica/lib/`.

On Windows, `AGENTICA_PATH` is separated by `;` and takes drive and UNC roots,
the user root is `%LOCALAPPDATA%/agentica/lib/`, and there are no default
system roots. Empty `AGENTICA_PATH` entries are ignored; a relative entry gives
`CHECK-IMPORT-PATH` when resolving a `pkg/` import. The first existing file
wins, and a read or syntax error in it does not fall back to another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash and
colon components, and must stay inside their root after symlink resolution. A
missing module is `CHECK-IMPORT-IO` at the import.

`Std.source(path: String) -> Result[String]` returns the source of an embedded
std/ module by its path in `stdlib/` (`"queue.agc"`), or an error.

## String queue (`std/queue`)

An immutable first-in, first-out queue of Strings: `Queue.new`, `push`, `pop`,
`peek`, `size`, `empty?` (signatures: `agentica doc std/queue`). Every function
returns a new queue (`QueueState`); `pop` gives `Popped(value, remaining)` and
`pop` or `peek` on an empty queue an error Result. There are no blocking
cross-task operations, and the operations are O(n).
