# File modules and imports

Each file is a module. `import Models from "models"` loads `models.agc` and
names it `Models`; `import Util from "../lib/util"` loads `../lib/util.agc`.
Paths never include the extension (`import "models.agc"` is
`CHECK-IMPORT-PATH`, and so are an empty path, a path ending in `/`, or a last
part with a dot such as `"models.rb"`): a module file name has no dot except
`.agc` (`json.tools.agc` cannot be imported).

- Relative paths resolve from the importing file, not the working directory.
- Every file, imported ones included, keeps the order: `import`s, constants,
  `struct` and `enum`, `export def`, private `def`. An imported file out of
  order is `CHECK-DECL-ORDER`, located in that file.
- Canonical paths identify files and each file is linked once. A cycle is
  `CHECK-IMPORT-CYCLE`; a missing or unreadable import `CHECK-IMPORT-IO`; an
  invalid path `CHECK-IMPORT-PATH`; each is reported at the import.

## Exports and names

`export struct`, `export enum`, `export def` and `export NAME = ...` (a
constant) expose declarations; everything else is private. Imports cannot be
re-exported. An exported signature may mention private types, but importers
cannot name or build them.

- Through the alias: `Models.User` in annotations and JSON type arguments,
  `Models.User(name: "Ana")` to construct, `Models.greet(user)` to call,
  `&Models.greet` for a callback; imported enums: `Models.Option[T]`,
  `Models.Option.Some(value)`, and `Models.Option.Some(item)` in a pattern.
  Local names stay unqualified inside their own file.
- Alias names are uppercase and cannot collide with declarations, other aliases,
  imported names or builtin names.

## Importing names

`import {User, greet} from "models"` brings exported names in, used bare:
`User` as a type, `User(name: "Ana")`, `greet(user)`, `user |> greet()`,
`&greet`, and for an enum `Option` the type `Option[T]`, `Option.None`,
`Option.Some(value)` and `Option.Some(item)` in a pattern. Variants are not
imported alone: import the enum. A bare function still needs parentheses.

- An entry may rename: `import {greet as hello, User as Account} from
  "models"`. The new name keeps the case rule of what it names (a struct or enum
  capitalized, a function lowercase), else `CHECK-IMPORT-RENAME` at the new
  name. The original name is not bound by a rename.
  `{greet as hello, greet as hi}` is allowed.
- The list may span lines, end with a comma, and may not be empty. `from` and
  `as` are not reserved: `{as}` imports a function called `as`.
- One line does one thing: `import Models, {User} from "models"` is a parse
  error; write two lines (two lines with one path load the file once). A module
  imported only by names has no alias, so `Models.` is unavailable for it.
- An imported name joins the file's names. It cannot equal a declaration, an
  alias, another imported name (the same name twice too), a builtin function
  (`puts`, `ok`) or a reserved type (`Int`, `JSON`, `HttpWire`):
  `CHECK-REDEFINED-NAME` at the name (at the new name of a rename).
- A name the module does not export, or keeps private, is `CHECK-IMPORT-NAME` at
  the name in the braces, with a `did you mean` help; it is reported at the
  import, before any use.
- A module imported by names counts as imported for `value.with(...)`: the file
  may update every exported struct of it.

## Constants

`export LIMIT = 100` shares a constant; `import {LIMIT, TABLE as LOOKUP} from
"limits"` brings it in by name, read bare. A constant can be renamed only to
another constant name (capitals and underscores): `{LIMIT as max}` is
`CHECK-IMPORT-RENAME`. It is not reached through the alias: `Limits.LIMIT` is
`CHECK-IMPORT-NAME` (the help says to write `import {LIMIT} from "limits"`); to
offer a value through the alias, export a function. An imported constant cannot
equal a constant or another name of the file (`CHECK-REDEFINED-NAME`); a private
constant cannot be imported (`CHECK-IMPORT-NAME`). The constants of the imported
files that the program can reach are built before `main`.

## Running

Only the root file's `def main() -> Void` runs; imported `main` functions never
run. Linking keeps source spans and distinct module identities. Imported calls
and tasks share the program's execution budget and resource ownership.
`agentica check`, `agentica FILE`, `agentica --dump` and `agentica test` use the
same loader. There are no wildcard imports, package registry, mutable module
state, nested module blocks or receiver attachment.

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

On Windows, `AGENTICA_PATH` is separated by `;` and takes drive (`C:\libs`,
`C:/libs`) and UNC (`\\server\share`) roots, and `/foo` and `\foo` (from the
root of the current drive); `C:libs` is relative. The user root is
`%LOCALAPPDATA%/agentica/lib/` (left out when the variable is unset or relative;
`XDG_DATA_HOME` and `HOME` are not read) and there are no default system roots.
Empty `AGENTICA_PATH` entries are ignored; a relative entry gives
`CHECK-IMPORT-PATH` when resolving a `pkg/` import. The first existing file
wins, and a read or syntax error in it does not fall back to another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash and
colon components. An external target must stay inside its root after symlink
resolution. These rules apply to namespaced imports only; ordinary relative
imports are not a filesystem sandbox. A missing module is `CHECK-IMPORT-IO` at
the import. Embedded-module diagnostics name their source (`std/queue.agc`).
Embedded modules may use relative paths within their stdlib directory; external
modules may use ordinary relative imports for their dependencies.

`Std.source(path: String) -> Result[String]` returns the source of a std/ module
embedded in this binary, by its path in `stdlib/` (`"queue.agc"`,
`"prelude/list.agc"`), or an error. `FrontEnd.hand_off` and
`FrontEnd.std_source` are for the compiler's own front end: any other program
halts with `RUNTIME-FRONT-END-ONLY`.

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
  `-`, at most 64 characters (the optional top-level `name` follows the same
  rule). Only git sources exist; a `path`, a branch or a version range is
  `PKG-MANIFEST-INVALID`.
- `subdir = "postgres"` makes the package a folder of the repository (several
  packages in one repository, prefixed tags such as `postgres-0.1.0`): plain
  folder names joined by `/`, at most 128 characters, no `..`, no leading `/`,
  no hidden folder, no `agc_libs`, else `PKG-MANIFEST-INVALID` at
  `dependencies.<name>.subdir`. The folder holds the package's `agentica.toml`;
  relative imports cannot leave it; the lock keeps `subdir` and the hash covers
  only that folder. Another folder of the same repository is a dependency like
  any other.
- A repository of packages can be a workspace (like npm): its root
  `agentica.toml` has `[workspace]` with `repository = "<git URL>"` and
  `members = ["sqlite", "postgres"]` (folders written like a `subdir`, each
  with its own `agentica.toml`); a bad table is `PKG-MANIFEST-INVALID` at
  `workspace.<key>` or `workspace.members[n]`. A project that is the root or
  a member (found by going up to the nearest manifest with the table; a table
  that does not list the project is ignored for it; a package of `deps/` is
  never in a workspace) reads a dependency whose `git` is the
  `repository` and whose `subdir` is a member from that member's folder: no
  fetch, no copy to `deps/`, no hash, so an edit is seen at once. Its manifest
  entry stays normal (`git`, `tag`, `subdir`); its lock entry has
  `workspace = true` and no `commit` or `hash`. Outside the repository, and
  for a package of the cache or `deps/`, the table is ignored and the
  dependency is fetched. A lock that disagrees with the workspace is
  `PKG-LOCK-STALE`.
- `pkg/<name>/<module path>` (no `.agc`) imports a module of a declared package.
  A declared name comes before the `pkg/` library folders (`agc_libs/` too); an
  undeclared name is the search above. The files of a package come only from
  `deps/<name>/` beside `agentica.toml`, never from the cache (a workspace
  member comes from its folder).
- A file of a package imports only the names of its own `agentica.toml`, and its
  own modules by relative paths inside the package.
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

  `tag` or `ref` is copied from the manifest. A `ref` must be the start of the
  `commit`. A missing lock is `PKG-LOCK-MISSING`. A dependency the lock lacks is
  `PKG-LOCK-STALE`, in the manifest of the project or of a package. A dependency
  with another repository or pin than the lock is `PKG-LOCK-STALE` in the
  project manifest and `PKG-SOURCE-CONFLICT` in a package manifest. A bad lock
  (a `version` other than 1, a name twice, a bad value) is `PKG-LOCK-INVALID`; a
  bad manifest `PKG-MANIFEST-INVALID`. Both name a file and a key path.
- The cache folder of a package is `<cache>/<host>/<owner>/<repo>/<commit>/`,
  with no `.git` in `<repo>` (`<commit>@<subdir>` with `/` written `@` for a
  `subdir`, holding only that folder). `agentica install` (no arguments; the
  project of the working folder) fills it with the system `git`, writes `deps/`
  from it and never writes the lock. A package already cached with the locked
  hash is not fetched, so a full cache needs no git and no network. A fetch gets
  the tag (or the locked commit) without a checkout and copies the `.agc` files
  (each at most 1 MiB) and the root `agentica.toml`. It fails with
  `PKG-TAG-MOVED` (the tag is another commit than the lock), `PKG-HASH-MISMATCH`
  (the files are not the locked ones; a cached folder is never overwritten),
  `PKG-SYMLINK`, `PKG-PATH-COLLISION` (two paths differing only in case),
  `PKG-FETCH` (git failed, no such tag or commit, cache not writable) and
  `PKG-MANIFEST-MISSING` (no `agentica.toml`). Each names `agentica.lock` and
  the entry's key, such as `package[0].tag`. `<cache>` is
  `$XDG_CACHE_HOME/agentica/pkg` when `XDG_CACHE_HOME` is absolute, else
  `~/.cache/agentica/pkg`; on Windows `%LOCALAPPDATA%\agentica\cache\pkg`.
- `add` and `update` run `git` as `install` does and write `agentica.lock`
  (every package of the build, sorted by name, and no other). `add` puts one
  line in `[dependencies]` of `agentica.toml` and changes no other byte; a name
  that is a dependency already is `PKG-DEPENDENCY-EXISTS`, and a layout the edit
  cannot handle (`dependencies = {}`) is `PKG-MANIFEST-EDIT`: write the line by
  hand. `update` with no name fetches every tag again (a moved tag is the new
  commit); with a name, that dependency only (not a dependency:
  `PKG-DEPENDENCY-UNKNOWN`). It also makes a missing or stale lock right. A
  commit pin never moves. A bad name, URL, tag or commit on the command line is
  a usage error (exit 2). A lock that cannot be written, or a manifest that
  changed during the fetch, is `PKG-WRITE`. Nothing is written when a step
  before the lock fails; if only the manifest write fails, run `agentica update`
  to make the lock match it again. Both then refresh `deps/` and remove the
  folder of a package the lock dropped.
- `deps/<name>/` holds the `.agc` files and the `agentica.toml` of each locked
  package that is not a workspace member, direct or not, flat (for a `subdir`,
  that folder only). `install` replaces the folder of each locked package that
  is not a real folder or whose `.agc` files differ from the lock (run it again
  to restore an edited file) and leaves every other entry of `deps/` alone (a
  killed run may leave a hidden `.tmp-*` or `.old-*` entry; the next command
  removes it once it is older than ten minutes). The
  tool writes no `.gitignore` there: commit `deps/` or ignore it. `deps/` as a
  symbolic link is `PKG-SYMLINK`; a failed write is `PKG-WRITE` (after `add` or
  `update` saved the lock, run `agentica install` to write the locked packages
  into `deps/`). `test` and
  `symbol` walks skip the `deps/` of a project. `agc_libs/` stays for local
  libraries.
- The hash is `sha256:` and the SHA-256 in hex (`Crypto.sha256`) of one byte
  stream: for each `.agc` file below the package folder, in bytewise order of
  its path relative to the folder (written with `/`), the path, a zero byte, the
  size in decimal, a zero byte and the file bytes. Hidden folders (any depth),
  `agc_libs/` at the package root and non-`.agc` files are left out, so the
  package's `agentica.toml` is not hashed. A build hashes a package (its
  `deps/` folder) the first time an import loads it; a difference is
  `PKG-HASH-MISMATCH`, and a symbolic link named `*.agc` is `PKG-SYMLINK`.

## String queue (`std/queue`)

Written in Agentica. Exported records: `QueueState(items: List[String])` and
`Popped(value: String, remaining: QueueState)`. Functions: `new`, `push`,
`pop`, `peek`, `size`, `empty?` (signatures: `agentica doc std/queue`). Push
adds at the back; pop removes the oldest value; pop and peek on an empty queue
return an error Result. Inputs never change: assign the returned queue (or
`Popped.remaining`). Empty strings and duplicates are valid. `QueueState` is a
normal exported struct, not an opaque handle. There are no user generics or
blocking cross-task queue operations. `push`, `pop`, `peek`, `size` and
`empty?` are O(n); no constant-time FIFO is promised.
