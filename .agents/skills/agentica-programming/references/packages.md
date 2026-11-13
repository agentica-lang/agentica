# Packages (`agentica.toml`)

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
  A declared name comes before the `pkg/` library folders; an undeclared name is
  the library search of `modules.md`. The files of a package come only from
  `deps/<name>/` beside `agentica.toml`, never from the cache. A package file
  imports only the names of its own `agentica.toml`, and its own modules by
  relative paths.
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
