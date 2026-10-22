# File modules and imports

Each file is a module. `import Models from "models"` loads `models.agc` and
names it `Models`; `import Util from "../lib/util"` loads `../lib/util.agc`.
Paths never include the extension (`import "models.agc"` is `CHECK-IMPORT-PATH`,
and so are an empty path, a path ending in `/`, or a last part with a dot such
as `"models.rb"`). So a module file name has no dot except `.agc`:
`json.tools.agc` cannot be imported; rename it `json_tools.agc`.

- Relative paths resolve from the importing file, not the working directory.
- Every file, imported ones included, keeps the order: `import`s, then
  constants, then `struct` and `enum`, then `export def`, then private `def`. An
  imported file out of order is `CHECK-DECL-ORDER`, located in that file.
- Canonical paths identify files, and each file is linked once. A cycle is
  `CHECK-IMPORT-CYCLE`; a missing or unreadable import is `CHECK-IMPORT-IO`; an
  invalid path is `CHECK-IMPORT-PATH`. Each is reported at the import.

## Exports and names

`export struct`, `export enum`, `export def`, and `export NAME = ...` (a
constant) expose declarations; everything else is private.

- Use `Models.User` in annotations and JSON type arguments, `Models.User(name:
  "Ana")` to construct, `Models.greet(user)` to call, and `&Models.greet` for a
  callback.
- Imported enums: `Models.Option[T]` as a type, `Models.Option.Some(value)` to
  build, and `Models.Option.Some(item)` in a pattern.
- Local names stay unqualified inside their own file.
- Alias names are uppercase and cannot collide with declarations, other aliases,
  imported names, or builtin names. Imports cannot be re-exported.
- An exported signature may mention private types, but importers cannot name or
  build them.

## Importing names

`import {User, greet} from "models"` brings exported names into the file, used
bare: `User` as a type, `User(name: "Ana")`, `greet(user)`, `user |> greet()`,
`&greet`, and for an enum `Option` the type `Option[T]`, `Option.None`,
`Option.Some(value)` and `Option.Some(item)` in a pattern. Variants are not
imported on their own: import the enum. A bare function still needs parentheses.

- An entry may rename: `import {greet as hello, User as Account} from "models"`
  binds `hello` and `Account`. Use it when two modules export the same name or a
  name is long. The new name keeps the case rule of what it names: a struct or
  enum becomes a capitalized name and a function a lowercase one, else
  `CHECK-IMPORT-RENAME` at the new name. The original name is not bound by a
  rename. `{greet as hello, greet as hi}` is allowed.
- The list may span lines, may end with a comma, and may not be empty. `from`
  and `as` are not reserved words: `{as}` imports a function called `as`.
- One line does one thing: `import Models, {User} from "models"` is a parse
  error. Write two lines; two lines with the same path load the file once. A
  module imported only by names has no alias, so `Models.` is not available for
  it.
- An imported name joins the names of the file. It cannot equal a declaration,
  an alias, another imported name (also the same name from the same module
  twice), a builtin function (`puts`, `ok`) or a reserved type (`Int`, `JSON`,
  `HttpWire`): `CHECK-REDEFINED-NAME` at the name (at the new name of a rename).
- A name the module does not export, or keeps private, is `CHECK-IMPORT-NAME` at
  the name in the braces, with a `did you mean` help over the exports. It is
  reported at the import, before any use.
- A module imported by names counts as imported for `value.with(...)`: the file
  may update every exported struct of it.

## Constants

`export LIMIT = 100` shares a constant; `import {LIMIT, TABLE as LOOKUP} from
"limits"` brings it in by name and it is read bare. A constant can be renamed
only to another constant name (capitals and underscores): `{LIMIT as max}` is
`CHECK-IMPORT-RENAME`. It is not reached through the alias: `Limits.LIMIT` is
`CHECK-IMPORT-NAME`, and the help says `write import {LIMIT} from "limits", then
use LIMIT`. To offer a value through the alias, export a function. An imported
constant cannot equal a constant or another name of the file
(`CHECK-REDEFINED-NAME`); a private constant cannot be imported
(`CHECK-IMPORT-NAME`). The constants of the imported files that the program can
reach are built before `main`.

## Running

Only the root file's `def main() -> Void` runs; imported `main` functions never
run. Linking keeps source spans and distinct module identities. Imported calls
and tasks share the program's execution budget and resource ownership.
`agentica check`, `agentica FILE`, `agentica --dump`, and
`agentica test` use the same loader.

There are no wildcard imports, package registry, mutable module state, nested
module blocks, or receiver attachment.

## Standard library and external libraries

Two prefixes select where a module comes from:

- `import Queue from "std/queue"` loads the standard library embedded at build
  time. No installation, environment variable, or checkout is needed at run
  time. Local files and external roots cannot shadow it.
- `import Tools from "pkg/acme/tools"` searches for `acme/tools.agc` in, in
  order:
  1. `agc_libs/` beside the root program (not beside each dependency, and not
     the working directory), or beside `agentica.toml` when the project has one;
  2. absolute roots in `AGENTICA_PATH`, in the listed order;
  3. `$XDG_DATA_HOME/agentica/lib/`, defaulting to
     `~/.local/share/agentica/lib/`;
  4. `/usr/local/share/agentica/lib/`, then `/usr/share/agentica/lib/`.

On Windows, `AGENTICA_PATH` is separated by `;` and takes drive (`C:\libs`,
`C:/libs`) and UNC (`\\server\share`) roots, and also `/foo` and `\foo` (from
the root of the current drive); `C:libs` is relative. The user root is
`%LOCALAPPDATA%/agentica/lib/` (left out when the variable is unset or
relative; `XDG_DATA_HOME` and `HOME` are not read), and there are no default
system roots. Empty `AGENTICA_PATH` entries are ignored; a relative
entry gives `CHECK-IMPORT-PATH` when resolving a `pkg/` import. The first
existing file wins, and a read or syntax error in it does not fall back to
another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash, and
colon components. An external target must stay inside its root after symlink
resolution. These rules apply to namespaced imports only; ordinary relative
imports are not a filesystem sandbox. A missing module is `CHECK-IMPORT-IO` at
the import. Embedded-module diagnostics name their source, such as
`std/queue.agc`. Embedded modules may use relative paths within their stdlib
directory; external modules may use ordinary relative imports for their
dependencies.

## Packages (`agentica.toml`)

A project with an `agentica.toml` in the folder of the root file (or above it)
can import the packages it declares. A build never downloads and never writes
`agentica.lock`: write the lock by hand and run `agentica install` to fill the
cache. A declared package that is not in the cache is `CHECK-IMPORT-PACKAGE`.

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }
```

```ruby
import Sqlite from "pkg/sqlite/db"
```

- A dependency is a local name and a table with `git`
  (`https://host/owner/repo`) and exactly one of `tag` or `ref` (a commit). A
  name starts with a lowercase letter, then lowercase letters, digits, `_` and
  `-`, at most 64 characters (`name` at the top is optional and follows the
  same rule). Only git sources exist; a `path`, a branch or a version range is
  `PKG-MANIFEST-INVALID`.
- `pkg/<name>/<module path>` (no `.agc`) imports a module of a declared
  package. A declared name comes before the `pkg/` library folders; an
  undeclared name is the search above.
- A file of a package imports only the names of its own `agentica.toml`, and
  its own modules by relative paths inside the package.
- A manifest with dependencies needs `agentica.lock` beside it. Only the lock
  of the project is read. It lists every package of the build, direct or not,
  once per name:

  ```toml
  version = 1

  [[package]]
  name = "sqlite"
  git = "https://github.com/owner/sqlite-ac"
  tag = "v1.2.0"
  commit = "<40 or 64 lowercase hex digits>"
  hash = "sha256:<64 lowercase hex digits>"
  ```

  `tag` or `ref` is copied from the manifest. A `ref` must be the start of the
  `commit`. A missing lock is `PKG-LOCK-MISSING`. A dependency that the lock
  lacks is `PKG-LOCK-STALE`, in the manifest of the project or of a package. A
  dependency with another repository or pin than the lock is `PKG-LOCK-STALE`
  in the project manifest and `PKG-SOURCE-CONFLICT` in a package manifest. A
  bad lock (a `version` other than 1, a name twice, a bad value) is
  `PKG-LOCK-INVALID`; a bad manifest is `PKG-MANIFEST-INVALID`. Both name a
  file and a key path.
- The cache folder of a package is
  `<cache>/<host>/<owner>/<repo>/<commit>/`, with no `.git` in `<repo>`.
  `agentica install` (no arguments; the project of the working folder) fills it
  with the system `git` and never writes the lock. A package already cached
  with the locked hash is not fetched, so a full cache needs no git and no
  network. A fetch gets the tag (or the locked commit) without a checkout and
  copies the `.agc` files and the root `agentica.toml`. It fails with
  `PKG-TAG-MOVED` (the tag is another commit than the lock), `PKG-HASH-MISMATCH`
  (the files are not the locked ones; a cached folder is never overwritten),
  `PKG-SYMLINK`, `PKG-PATH-COLLISION` (two paths that differ only in case),
  `PKG-FETCH` (git failed, no such tag or commit, cache not writable) and
  `PKG-MANIFEST-MISSING` (no `agentica.toml`). Each names `agentica.lock` and
  the key of the entry, such as `package[0].tag`.
  `<cache>` is `$XDG_CACHE_HOME/agentica/pkg` when `XDG_CACHE_HOME` is an
  absolute path, else `~/.cache/agentica/pkg`; on Windows it is
  `%LOCALAPPDATA%\agentica\cache\pkg`.
- The hash is `sha256:` and the SHA-256 in hex (`Crypto.sha256`) of one byte
  stream. For each `.agc` file below the package folder, in bytewise order of
  its path relative to the folder (written with `/`), the stream holds the
  path, a zero byte, the size in decimal, a zero byte and the file bytes.
  Hidden folders (at any depth), `agc_libs/` at the root of the package and
  files that are not `.agc` are left out, so the `agentica.toml` of a package is
  not hashed. A build hashes a package the first time an import loads it; a
  difference is `PKG-HASH-MISMATCH`, and a symbolic link named `*.agc` is
  `PKG-SYMLINK`.

## String queue (`std/queue`)

`std/queue` is a library written in Agentica. Its exported records are
`QueueState(items: List[String])` and `Popped(value: String, remaining:
QueueState)`. Its functions are `new`, `push`, `pop`, `peek`, `size` and
`empty?` (signatures: `agentica doc std/queue`). Push adds at the back; pop
removes the oldest value. Pop and peek on an empty queue return an error
Result. Inputs are never changed: assign the returned
queue (or `Popped.remaining`). Empty strings and duplicates are valid.
`QueueState` is a normal exported struct, not an opaque handle. There are no
user generics and no blocking cross-task queue operations. `push`, `pop`,
`peek`, `size` and `empty?` are O(n); no constant-time FIFO is promised.
