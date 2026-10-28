---
title: Modules and imports
weight: 13
description: Split a program into files, export declarations and use the standard library.
---

## One file, one module

Each `.agc` file is a module. `export` makes a function, struct or enum visible to other files. Everything else stays private.

Save this as `shapes.agc`:

```agentica {file="shapes.agc"}
export struct Square
  side: Int
end

export def area(s: Square) -> Int
  return s.side * s.side
end

def secret() -> Int
  return 42
end
```

## File layout

Each file lists its declarations in this order (`CHECK-DECL-ORDER` otherwise):

```text
# module doc and imports
# constants (see Constants)
# struct, enum, type alias and extern block with a resource or a struct (its defs too), in any order
# export def
# def
```

A blank line goes before each declaration after the first.

A private function before an exported one is `CHECK-DECL-ORDER`:

```agentica {expect="CHECK-DECL-ORDER"}
def secret() -> Int
  return 42
end

export def reveal() -> Int
  return secret()
end

def main() -> Void
  puts(reveal())
end
```

## Import a file

`import` loads a file and gives it a name, the alias. Use the alias in front of every name from that file.

```agentica
import Shapes from "shapes"

def main() -> Void
  s = Shapes.Square(side: 3)
  puts(Shapes.area(s))
end
```

```output
9
```

Paths are relative to the importing file and leave out the `.agc` extension: `"shapes"` loads `shapes.agc`. Aliases start with an uppercase letter. Calling a private function is an error:

```agentica {expect="CHECK-IMPORT-NAME"}
import Shapes from "shapes"

def main() -> Void
  puts(Shapes.secret())
end
```

## Types and enums from a module

Imported types use the alias too: in annotations, in construction and in patterns.

```agentica {file="status.agc"}
export enum Status
  Active
  Banned(String)
end
```

```agentica
import S from "status"

def show(s: S.Status) -> String
  case s
    S.Status.Active -> return "active"
    S.Status.Banned(why) -> return "banned: #{why}"
  end
end

def main() -> Void
  puts(show(S.Status.Banned("spam")))
end
```

```output
banned: spam
```

A transparent type alias may be exported and imported in the same way. For example, `export type Names = List[String]` is used as `S.Names` or imported with `import {Names} from "status"`. A generic alias such as `export type Matrix[T] = List[List[T]]` works the same way: `S.Matrix[Int]`, or `Matrix[Int]` after `import {Matrix} from "status"`.

## Import names

`import Alias from "path"` gives the file the alias `Alias`. To skip the alias, list the exported names you want in braces and use them bare:

```agentica
import {Square, area} from "shapes"

def main() -> Void
  s = Square(side: 3)
  puts(area(s))
end
```

```output
9
```

This works for functions, structs, enums and constants. For an enum, import the enum, not its variants: its values and patterns keep the enum name in front.

```agentica
import {Status} from "status"

def show(s: Status) -> String
  case s
    Status.Active -> return "active"
    Status.Banned(why) -> return "banned: #{why}"
  end
end

def main() -> Void
  puts(show(Status.Banned("spam")))
end
```

```output
banned: spam
```

An entry may rename with `as`. A type keeps a capital name and a function a lowercase one (`CHECK-IMPORT-RENAME`). Renaming also lets two modules that export the same name both be imported:

```agentica
import {Square as Box, area as box_area} from "shapes"

def main() -> Void
  puts(box_area(Box(side: 4)))
end
```

```output
16
```

A name the module does not export, or keeps private, is an error at the import:

```agentica {expect="CHECK-IMPORT-NAME"}
import {Square, secret} from "shapes"

def main() -> Void
  puts(secret())
end
```

An imported name cannot clash with a declaration, an alias, another import or a builtin (`CHECK-REDEFINED-NAME`). A path may appear in two imports, one with an alias and one with names. A module imported only by names has no alias.

Only the root file needs `main`. Imported files have no top-level code, so importing a file never runs anything.

## Re-exports

A module can pass on a name it imports with `export Alias.name`, so a small facade file collects the API of several files. Save this as `geometry.agc`:

```agentica {file="geometry.agc"}
import Shapes from "shapes"

export Shapes.Square
export Shapes.area
```

The importer sees the original declaration: `Geometry.Square` and `Shapes.Square` are one type, and `&Geometry.area` and `&Shapes.area` are one function.

```agentica
import Geometry from "geometry"

def main() -> Void
  puts(Geometry.area(Geometry.Square(side: 5)))
end
```

```output
25
```

The alias must be an import of the file, and the module must export the name (`CHECK-IMPORT-NAME`). The name must not be a declaration, another re-export or an import alias of the file (`CHECK-REDEFINED-NAME`). There is no `as` and no wildcard: a facade that wants another name writes a wrapper function. A re-export adds no local name, so inside the facade the name is still `Shapes.area`. Re-exports follow the imports, and one after a declaration needs a blank line (`PARSE-MISSING-BLANK-LINE`).

## The standard library

Paths that start with `std/` load the standard library that ships with Agentica. `std/queue` is a first-in, first-out queue of strings:

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.new()
  q = Queue.push(q, "first")
  q = Queue.push(q, "second")
  case Queue.pop(q)
    ok(popped) ->
      puts(popped.value)
      puts(Queue.size(popped.remaining))
    error(message) -> puts(message)
  end
end
```

```output
first
1
```

See [Queue](/library/data-structures/queue/) for every function.

## Other libraries

Paths that start with `pkg/` load installed libraries. `import Tools from "pkg/acme/tools"` looks for `acme/tools.agc` in `agc_libs/` next to the main program (next to `agentica.toml` when the project has one), then in each directory listed in `AGENTICA_PATH`, then in `~/.local/share/agentica/lib/`, `/usr/local/share/agentica/lib/` and `/usr/share/agentica/lib/`. On Windows, `AGENTICA_PATH` is separated by `;` (drive paths such as `C:\libs` are fine), the user directory is `%LOCALAPPDATA%\agentica\lib\`, and there are no system directories.

## Packages

A package is a git repository of `.agc` files. A project with an `agentica.toml` next to its main file, or in a folder above it, can import the packages the manifest declares. Each dependency has a local name and one pin, a `tag` or a `ref` (a commit):

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }
```

Import a package by its local name, then a path inside the package, without `.agc`:

```text
import Sqlite from "pkg/sqlite/db"
```

The local name does not have to match the URL, so moving a repository changes only its `git` line.

One repository can hold several packages, each in its own folder. Name the folder with `subdir`, a relative path of plain folder names (letters, digits, `.`, `_` and `-`; no `..`, no leading `/`, no hidden folder, no `agc_libs`), and use prefixed tags for the versions:

```toml
[dependencies]
sqlite = { git = "https://github.com/owner/packages", tag = "sqlite-0.1.0", subdir = "sqlite" }
postgres = { git = "https://github.com/owner/packages", tag = "postgres-0.1.0", subdir = "postgres" }
```

The folder is the package: it has its own `agentica.toml`, its relative imports cannot leave it, the lock keeps its `subdir`, and the hash covers only its files, so a change in another folder of the repository changes nothing. The cache and `deps/` keep only that folder. A bad `subdir` is `PKG-MANIFEST-INVALID` at `dependencies.<name>.subdir`.

A repository of packages can also be a workspace, so that you can develop one package against another without tagging either. The `agentica.toml` at the root of the repository lists the repository and its member folders:

```toml
[workspace]
repository = "https://github.com/owner/packages"
members = ["sqlite", "postgres"]
```

- A member keeps its normal dependencies, the ones a user outside the repository resolves, such as `common = { git = "https://github.com/owner/packages", tag = "common-1.0.0", subdir = "common" }`.
- A project is in the workspace when its folder is the root or a member. In a workspace, a dependency whose `git` is the `repository` and whose `subdir` is a member is read from the member's folder: it is not fetched, not copied to `deps/`, and an edit there is seen by the next build, with no tag and no `agentica install`. Its lock entry says `workspace = true` and has no `commit` and no `hash`.
- A project outside the repository resolves the same dependency through the cache and `deps/` as usual. A `[workspace]` table in a package of the cache or of `deps/` is ignored.
- A bad table is `PKG-MANIFEST-INVALID` at `workspace.repository`, `workspace.members` or `workspace.members[n]`; a lock that disagrees with the workspace is `PKG-LOCK-STALE`.

A package can use a native library from its `extern` blocks (see [Native code](/library/io-and-system/native/)). Its `agentica.toml` names the library for each system it exists on (`linux`, `macos` or `windows`), as a `file` in the package's `native/` folder, as a `system` name that the system loader looks up (or an absolute path, or a list of them), or as a download `{ url, sha256, member }` pinned per system in `[[native-artifact]]` and fetched by `install`/`update`:

```toml
[native.sqlite3]
linux = { system = "libsqlite3.so.0" }
macos = { system = "libsqlite3.dylib" }
windows = { file = "native/windows/sqlite3.dll" }
```

- A `system` list gives candidates in order of preference, as bare names or absolute paths: `macos = { system = ["libpq.5.dylib", "/opt/homebrew/opt/libpq/lib/libpq.5.dylib"] }`. The first absolute path that is a file wins, else the first bare name, else the first path. A macOS path in the dyld shared cache (such as `/usr/lib/libz.dylib`) does not count as existing. The working directory is never searched. A relative path, an empty list or an item that is not a string is `PKG-MANIFEST-INVALID` at the key of the item.
- In the files of that package, `extern "sqlite3"` means the entry of the system the program runs on. A `file` is opened by its absolute path in `deps/`, so `LD_LIBRARY_PATH` plays no part; a macOS file must be a universal binary. Like every file of a package, a library is at most 1 MiB.
- The files of `native/` (dotfiles, `Thumbs.db` and `desktop.ini` aside) are copied and hashed with the package, so a changed library or manifest is `PKG-HASH-MISMATCH`. A link named `native` is `PKG-SYMLINK`, and a `file` that names `Thumbs.db` or `desktop.ini` is `PKG-MANIFEST-INVALID`.
- A package with no entry for your system is `PKG-NATIVE-PLATFORM` where a file uses the library; a `file` the package lacks is `PKG-NATIVE-MISSING`.
- Native code is allowed by default; `--deny-native` and `--sandbox` refuse the program as they refuse any `extern`. The `[native]` table of the project's own `agentica.toml` works the same, with paths relative to the project and no hash.
- The bytecode that `agentica compile` writes holds the absolute path of the file, and `agentica run -- file.agcb` opens whatever is there, with no hash check.

The optional `[style]` table of `agentica.toml` applies to the files below its folder that have no nearer `agentica.toml`. Libraries are not checked (not `std/`, not a package, not `agc_libs/`). With `blank_line_after_end = true` (a boolean, false by default; another value is `PKG-MANIFEST-INVALID`), a line that holds only `end` needs an empty line after it, or `agentica check` reports `CHECK-BLANK-LINE-AFTER-END`. The next line may instead start with `end`, `else`, `elsif`, `)`, `]`, `}` or `.name`, and the last `end` of a file needs nothing after it.

A declared name comes before the `pkg/` library folders (`agc_libs/` too), so it hides a library of the same name there. A file of a package imports only the packages that its own `agentica.toml` declares.

A manifest that declares dependencies needs an `agentica.lock` beside it. The lock holds the exact commit and a hash of the `.agc` files of every package, direct or not. A build never downloads anything: it finds each package by its commit and checks its hash when an import first loads it.

The packages come only from `deps/<name>/` next to `agentica.toml`, one folder for each package of the lock that is not a workspace member. A package that `deps/` lacks is `CHECK-IMPORT-PACKAGE`, and the help says to run `agentica install`. Commit `deps/` or ignore it as you like (the tool writes no `.gitignore` there); a committed `deps/` needs no `agentica install` to build. A new unused file in `deps/` is caught by `check` or `--no-cache`, not by a cached run. `agentica test` and `agentica symbol` skip `deps/`.

`agentica install` runs the system `git`, so your git config, SSH keys and credential helpers apply. It never changes the lock.

- For each package of the lock that is not in the download cache, `~/.cache/agentica/pkg/<host>/<owner>/<repo>/<commit>/` (on Windows `%LOCALAPPDATA%\agentica\cache\pkg\`; an absolute `XDG_CACHE_HOME` replaces `~/.cache`), it fetches the tag or the locked commit without a checkout and checks the commit and the hash of the `.agc` files against the lock. A full cache needs no `git` and no network.
- Then it writes every package of the lock into `deps/<name>/`, checking the hash again. A folder whose `.agc` files differ from the lock is replaced by the locked files, a folder with the locked hash is left as it is, and other files and folders stay. A lock that fails the checks writes nothing; a failure in the middle of the copy leaves `deps/` partly updated, and running `agentica install` again finishes it.
- `deps/` must be a real folder, not a link (`PKG-SYMLINK`). Only the `.agc` files, the files of `native/` and the `agentica.toml` of the package are copied, each at most 1 MiB (16 MiB together); two paths that differ only in case are refused.
- Git may ask for a password on the terminal, and each git read has a 5 minute deadline. A tag that now points to another commit is `PKG-TAG-MOVED`; files that are not the locked ones are `PKG-HASH-MISMATCH`; a git failure is `PKG-FETCH`.

```sh
agentica install
```

`agentica add` and `agentica update` write the lock, so you do not write it by hand. Both start `git` and may use the network.

- `add` takes the local name, the `https://` URL and a tag (or a whole commit id with `--ref`), and `--subdir DIR` for a folder of the repository. It fetches the package and the packages in its own `agentica.toml`, and writes `agentica.lock`, one new line of `[dependencies]` in `agentica.toml` (your comments stay) and `deps/`.
- `update` fetches the tag pins again, all of them or the one dependency you name; a pin that is a commit does not move. It also repairs a lock that is missing or out of date after you edit the manifest.
- Both refresh `deps/` and remove the folder of a package that the lock no longer holds. If `deps/` cannot be written, the lock is saved already and the help says to run `agentica install`. Nothing is written if a step before the lock fails.

```sh
agentica add sqlite https://github.com/owner/sqlite-ac --tag v1.2.0
agentica add postgres https://github.com/owner/packages --tag postgres-0.1.0 --subdir postgres
agentica update sqlite
```

Problems are reported with `PKG-` codes: a bad manifest or lock, a lock that does not match the manifest, one name with two sources, or a package file that changed, or a fetch that failed. A declared package that is not in `deps/` is `CHECK-IMPORT-PACKAGE`.

Import cycles are errors (`CHECK-IMPORT-CYCLE`), and so are missing files (`CHECK-IMPORT-IO`).
