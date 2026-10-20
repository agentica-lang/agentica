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
and tasks share the program's execution budget and resource ownership. `agentica
check`, `agentica FILE`, `agentica --dump`, and `agentica test` use the same
loader.

There are no wildcard imports, package registry, mutable module state, nested
module blocks, or receiver attachment. `as` and `from` are contextual in
imports, not reserved.

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

A package is a git repository of `.agc` files. A project with an
`agentica.toml` in the folder of the root file (or above it) can import the
packages it declares. This version only reads the cache: nothing downloads, so
the cache has to be filled already (`agentica install` comes later).

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }
```

```ruby
import Sqlite from "pkg/sqlite/db"
import Json from "pkg/json5/util/json"
```

- A dependency is a local name (a lowercase letter, then lowercase letters,
  digits, `_` and `-`) and a table with `git` (`https://host/owner/repo`, an
  optional `.git` at the end; the owner and the repository do not end in `.` and
  are not Windows device names such as `con`) and exactly one of `tag` (1 to 128
  letters, digits and `. _ + -`; no `/`, not starting with `.` or `-`) or `ref`
  (a commit, 7 to 64 lowercase hex digits). Only `git` sources exist: a `path`,
  a branch or a version range is `PKG-MANIFEST-INVALID`.
- The import is `pkg/<name>/<module path>` without `.agc`. A declared name is a
  package and shadows a library of the same name in `agc_libs/` and the other
  `pkg/` roots; an undeclared name is the `pkg/` search above, unchanged.
- A file of the project imports the names of the project's manifest. A file of
  a package imports only the names of its own `agentica.toml` (never out of the
  package by `../`, never a hidden folder or `agc_libs/`); another `pkg/` name
  there is `CHECK-IMPORT-PACKAGE`. Its own modules are relative paths.
- `agentica.lock` (TOML, beside the manifest) has one `[[package]]` for each
  name of the whole project, direct or not: `name`, `git`, `tag` or `ref`,
  `commit`, `hash`. A manifest with dependencies and no lock is
  `PKG-LOCK-MISSING`; a dependency the lock lacks or holds with another source
  is `PKG-LOCK-STALE`; one name with two sources between the project and its
  packages is `PKG-SOURCE-CONFLICT`, found in the manifests of all locked
  packages that are in the cache, imported or not; a bad file is
  `PKG-MANIFEST-INVALID` or `PKG-LOCK-INVALID`, at a file and key path (a file
  that is missing or unreadable has no key path and no position). A manifest of
  a package that is a link or not a regular file is `PKG-SYMLINK`. A build never
  writes the lock.
- The cache is `$XDG_CACHE_HOME/agentica/pkg/<host>/<owner>/<repo>/<commit>/`
  (`~/.cache` when `XDG_CACHE_HOME` is not absolute; on Windows
  `%LOCALAPPDATA%/agentica/cache/pkg/`). A package that is not there is
  `CHECK-IMPORT-PACKAGE`. When a build first imports a package it hashes its
  `.agc` files and compares them with the lock: a changed, added or missing
  file is `PKG-HASH-MISMATCH`.
- A package file is stored as `pkg/<name>@<tag>/path.agc` (the first 12 digits
  of the commit for a `ref`), so stack traces do not show the cache folder.
- `agc_libs/` for `pkg/` is beside `agentica.toml` when there is one.

## String queue (`std/queue`)

`std/queue` is a library written in Agentica. Its exported records are
`QueueState(items: List[String])` and `Popped(value: String, remaining:
QueueState)`. With the alias `Queue`:

```text
Queue.new() -> Queue.QueueState
Queue.push(q: Queue.QueueState, value: String) -> Queue.QueueState
Queue.pop(q: Queue.QueueState) -> Result[Queue.Popped]
Queue.peek(q: Queue.QueueState) -> Result[String]
Queue.size(q: Queue.QueueState) -> Int
Queue.empty?(q: Queue.QueueState) -> Bool
```

Push adds at the back; pop removes the oldest value. Pop and peek on an empty
queue return an error Result. Inputs are never changed: assign the returned
queue (or `Popped.remaining`). Empty strings and duplicates are valid.
`QueueState` is a normal exported struct, not an opaque handle. There are no
user generics and no blocking cross-task queue operations. The implementation
uses Lists: push, peek, size, empty? and new take near constant time, but pop is
O(n) because it drops the first item of the list; no constant-time FIFO is
promised.

## Other standard modules

- `std/http`: the HTTP client and server, written in Agentica. See `network.md`.
- `std/binary`: reads and writes binary numbers in a `List[Int]` of bytes. See
  `binary.md`.
- `std/toml`: reads and writes TOML 1.0. See `toml.md`.
- `std/logger`: levels, handlers, text and JSON lines on stderr. See
  `logger.md`.
- `std/bdd`: the step API of `agentica test`. See `bdd.md`.
