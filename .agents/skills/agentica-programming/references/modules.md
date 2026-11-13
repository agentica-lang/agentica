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
  `def`); `private`; the private part (constants, types and blocks, `def`). A
  file without `private` keeps the old order: `import`s, constants, types and
  blocks, `export def`, private `def`. An imported file out of order is
  `CHECK-DECL-ORDER`, located in that file.
- Each file is linked once. A cycle is `CHECK-IMPORT-CYCLE`; a missing or
  unreadable import `CHECK-IMPORT-IO`; an invalid path `CHECK-IMPORT-PATH`.
- An import alias that the file never uses is `CHECK-UNUSED-IMPORT`: remove
  the import. A use is any `Alias.name` or a re-export; a regex literal uses the
  `std/regex` import and a `<<~EAG` template the `std/eag` one. An alias with no
  member (`u: User`) is `CHECK-IMPORT-NAME`. Unused names of `import {a, b}` are
  fine.

## Public and private names

A `private` line, alone, splits a file: every declaration above it (constant,
struct, enum, type alias, function, module block) is public, every one after it
is private to the file. Write the API first:

```agentica
LIMIT = 10

def open(id: Int) -> Int = connect(id)

private

BUFFER = 4096

def connect(id: Int) -> Int = id + BUFFER
```

- One `private` per file or block (a second is `PARSE-SECOND-PRIVATE`), with a
  blank line before and after it. Imports are never public.
- In a file with `private`, `export` before a declaration is
  `PARSE-UNEXPECTED-TOKEN`. A file without `private` uses the older form:
  `export def`, `export struct`, `export enum`, `export type`, `export NAME =
  ...` and `export module` mark the public names, and the rest is private;
  `private` replaces it.
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
  above `private`, `Url` an alias of this file) passes on a name of an imported module, so a
  facade file collects an API. The importer gets the original declaration
  (`Web.Address` and `Url.Address` are one type, `&Web.parse` is `&Url.parse`);
  the file adds no local name. No `as`, no wildcard. An unknown alias or name
  is `CHECK-IMPORT-NAME`; a name that is also a declaration, re-export or
  alias of the file is `CHECK-REDEFINED-NAME`, so the alias must differ from
  the names it re-exports: `import V from "value"` with `export V.Value`, not
  `import Value ...` with `export Value.Value`.
- Alias names are uppercase and cannot collide with declarations, other aliases,
  imported names or builtin names.

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

A public constant (`LIMIT = 100` above `private`) is shared; `import {LIMIT, TABLE as LOOKUP} from
"limits"` brings it in by name, read bare. A constant can be renamed only to
another constant name (capitals and underscores): `{LIMIT as max}` is
`CHECK-IMPORT-RENAME`. An alias reads it too: `Limits.LIMIT`,
`Limits.TABLE.size`, `Limits.CONFIG.with(port: 81)`; a private one is
`CHECK-IMPORT-NAME`, `Limits.LIMIT()` is `CHECK-TYPE-MISMATCH`. An imported
constant cannot equal a constant or another name of the file
(`CHECK-REDEFINED-NAME`); a private constant cannot be imported
(`CHECK-IMPORT-NAME`). The constants of the imported
files that the program can reach are built before `main`.

## Module blocks

`module Counter ... end` at the top level groups declarations under a name, so
one file holds several modules (a namespace only). Inside: constants, structs,
enums, aliases and functions with the file's layout rules, and its own
`private` line: what is above it is visible outside as `Counter.start(0)`,
`Counter.Msg.Add(5)`, `Counter.LIMIT`. A private name is `CHECK-IMPORT-NAME`. The body sees the
file's imports, top-level names (private too) and other blocks; it may not
declare one of those names again (`CHECK-SHADOWED-NAME`) or `main`
(`CHECK-MAIN`), but two blocks may both have `start`. A block above the file's
`private` is importable: `import {Counter} from "agents"` (an alias) or
`Agents.Counter.start(0)`. The name follows the alias rules
(`CHECK-REDEFINED-NAME`); a block inside a block is `PARSE-NESTED-MODULE`; no
import, re-export or extern block inside.

## Running

Only the root file's `main` runs; imported `main` functions never run. There are
no wildcard imports, mutable module state or module blocks inside module blocks.

## Standard library and external libraries

- `import Queue from "std/queue"` loads the standard library embedded at build
  time: no installation, variable or checkout is needed, and local files and
  external roots cannot shadow it.
- `import Tools from "pkg/acme/tools"` searches for `acme/tools.agc` in order:
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

## Packages (`agentica.toml`)

A project with an `agentica.toml` in the folder of the root file (or above it)
can import the packages it declares. A build never downloads and never writes
`agentica.lock`: `agentica add NAME URL --tag TAG` (or `--ref COMMIT`, the whole
id; `--subdir DIR` for a folder of the repository) adds a dependency and writes
the lock, `agentica update [NAME]` moves tag pins, and `agentica install`
writes every locked package into `deps/<name>/` beside `agentica.toml` (through
a download cache). A build reads packages only from `deps/`; a declared package
missing there is `CHECK-IMPORT-PACKAGE`.

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
  `-`, at most 64 characters. A branch or a version range is
  `PKG-MANIFEST-INVALID`.
- `[style] max_line_width = N` makes a line of more than N characters (comments
  too) `CHECK-LINE-TOO-LONG`; `agentica fmt` lays out in N columns (default
  119). `[style] blank_line_after_end = true` (default false) makes a line with
  only `end` need an empty line after it (`CHECK-BLANK-LINE-AFTER-END`). Both
  apply to the files below the manifest's folder that have no manifest nearer,
  not to `std/`, packages, `agc_libs/` or `pkg/` libraries. After `end` the next
  line may start with `end`, `else`, `elsif`, `)`, `]`, `}` or `.name`.
- `agentica = "0.31.0"` is the oldest Agentica the project or package needs
  (one SemVer version, a minimum; pre-releases sort before their release).
  When the project, a locked package or the workspace root of a member needs a
  newer one, `install`, `check`, `run` and `test` fail with
  `PKG-AGENTICA-TOO-OLD` at `agentica`; a range or any other value is
  `PKG-MANIFEST-INVALID`.
- `[tool.NAME]` tables are for other tools and Agentica reads nothing inside
  them; `tool` or `tool.NAME` that is not a table is `PKG-MANIFEST-INVALID`.
- `subdir = "postgres"` makes the package a folder of the repository (several
  packages in one repository, prefixed tags such as `postgres-0.1.0`): plain
  folder names joined by `/`, no `..`, no leading `/`, no hidden folder, no
  `agc_libs`, else `PKG-MANIFEST-INVALID`. The folder holds the package's
  `agentica.toml`; relative imports cannot leave it; the hash covers only that
  folder.
- A repository of packages can be a workspace: its root `agentica.toml` has
  `[workspace]` with `repository = "<git URL>"` and `members = ["sqlite",
  "postgres"]` (folders written like a `subdir`, each with its own
  `agentica.toml`). A project that is the root or a member reads a dependency
  whose `git` is the `repository` and whose `subdir` is a member from that
  member's folder: no fetch, no copy to `deps/`, no hash, so an edit is seen at
  once. Its manifest entry stays normal; its lock entry has `workspace = true`
  and no `commit` or `hash`. Elsewhere the table is ignored. A lock that
  disagrees with the workspace is `PKG-LOCK-STALE`.
- Only the root `agentica.toml` may write `path = "../sqlite"` (a folder with
  an `agentica.toml`, relative to the manifest or absolute; no git keys with it)
  and `override = true` (this source wins for the name over every package that
  asks for another; with a `path` too). A `path` is read in place like a
  workspace member: no fetch, no `deps/`, no hash; its lock entry has `name` and
  `path`. An override is `override = true` in the lock entry. In a package's
  manifest either key is `PKG-ROOT-ONLY`. Without `override`, a name with two
  sources in the tree is `PKG-SOURCE-CONFLICT`. `install`, `add` and `update`
  print one `overridden NAME@VERSION` line for each overridden package.
- `pkg/<name>/<module path>` (no `.agc`) imports a module of a declared package.
  A declared name comes before the `pkg/` library folders; an undeclared name
  is the search above. The files of a package come only from `deps/<name>/`
  beside `agentica.toml`, never from the cache. A package file imports only the
  names of its own `agentica.toml`, and its own modules by relative paths.
- A manifest with dependencies needs `agentica.lock` beside it. Only the
  project's lock is read. It lists every package of the build, direct or not,
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

  `tag` or `ref` is copied from the manifest. A missing lock is
  `PKG-LOCK-MISSING`; a dependency the lock lacks, or with another repository or
  pin, is `PKG-LOCK-STALE` (`PKG-SOURCE-CONFLICT` in a package manifest); a bad
  lock or manifest is `PKG-LOCK-INVALID` or `PKG-MANIFEST-INVALID`, naming a
  file and a key path.
- `agentica install` fills a download cache with the system `git`, writes
  `deps/` from it and never writes the lock. A package already cached with the
  locked hash is not fetched, so a full cache needs no git and no network.
  Failures are the `PKG-` codes of `diagnostics.md`, each with the lock entry's
  key path (`package[0].tag`).
- `add` and `update` run `git` as `install` does and write `agentica.lock`
  (every package of the build, sorted by name). `add` puts one line in
  `[dependencies]` and changes no other byte of `agentica.toml`. `update` with
  no name fetches every tag again; with a name, that dependency only; it also
  makes a missing or stale lock right. A commit pin never moves. A bad name,
  URL, tag or commit on the command line is a usage error (exit 2). Nothing is
  written when a step before the lock fails; if only the manifest write fails,
  run `agentica update`. Both then refresh `deps/`.
- `deps/<name>/` holds the `.agc` files and the `agentica.toml` of each locked
  package that is not a workspace member, flat. `install` replaces a folder
  whose `.agc` files differ from the lock and leaves every other entry of
  `deps/` alone. The tool writes no `.gitignore` there: commit `deps/` or ignore
  it. `test`, `check`, `fmt` and `symbol` walks skip the `deps/` of a project
  and `_build/`; `agc_libs/` stays for local libraries.
- The package hash leaves out hidden folders and `_build/` (any depth) and
  `agc_libs/` and `deps/` at its root; a package cannot import a file there.
- A build hashes a package (its `deps/` folder) the first time an import loads
  it; a difference is `PKG-HASH-MISMATCH`, and a symbolic link named `*.agc`,
  `native` or in `native/` is `PKG-SYMLINK`.
- A package declares native libraries in its own `agentica.toml`, one table
  `[native.NAME]` each, with an inline table for each of `linux`, `macos` and
  `windows` that has exactly one of `file = "native/path"` (shipped in the
  package, at most 1 MiB, hashed with it), `system = "libname"` (a name the
  system loader looks up, or an absolute path; a list gives candidates, the
  first existing absolute path wins, else the first name), or `{ url, sha256,
  member }` (a pinned TAR or ZIP download):

  ```toml
  [native.sqlite3]
  linux = { system = "libsqlite3.so.0" }
  windows = { file = "native/windows/sqlite3.dll" }
  ```

  In the package's files, `extern "sqlite3"` then means the entry of the
  running system. A bad table is `PKG-MANIFEST-INVALID`; no entry for the system
  is `PKG-NATIVE-PLATFORM` and a missing file `PKG-NATIVE-MISSING`.
  `--deny-native` and `--sandbox` refuse such a program. The project's own
  `[native]` works for its own files (paths relative to the project, no hash).
  `agentica compile` bakes the absolute library path into the `.agcb`. A
  `build` key builds a native module from C sources instead
  (`native-modules.md`).

## String queue (`std/queue`)

An immutable first-in, first-out queue of Strings: `Queue.new`, `push`, `pop`,
`peek`, `size`, `empty?` (signatures: `agentica doc std/queue`). Every function
returns a new queue (`QueueState`); `pop` gives `Popped(value, remaining)` and
`pop` or `peek` on an empty queue an error Result. There are no blocking
cross-task operations, and the operations are O(n).
