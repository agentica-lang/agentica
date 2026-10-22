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
# struct, enum, type alias and extern resource, in any order
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

The folder is the package: it has its own `agentica.toml`, its relative imports cannot leave it, the lock keeps its `subdir`, and the hash covers only its files, so a change in another folder of the repository changes nothing. The cache and `deps/` keep only that folder. A package that needs another folder of its repository declares it as any other dependency. A bad `subdir` is `PKG-MANIFEST-INVALID` at `dependencies.<name>.subdir`.

A repository of packages can also be a workspace, like an npm workspace, so that you can develop one package against another without tagging either. The `agentica.toml` at the root of the repository lists the repository and its member folders:

```toml
[workspace]
repository = "https://github.com/owner/packages"
members = ["sqlite", "postgres"]
```

A member keeps its normal dependencies, the ones a user outside the repository resolves, such as `common = { git = "https://github.com/owner/packages", tag = "common-1.0.0", subdir = "common" }`. A project is in the workspace when its folder is the root or one of the members (the search goes up from the project folder to the nearest `agentica.toml` with a `[workspace]` table, and never into a package of `deps/`). In a workspace, a dependency whose `git` is the `repository` and whose `subdir` is a member is read from the member's folder: it is not fetched, it is not copied to `deps/`, and an edit there is seen by the next build, with no tag and no `agentica install`. Its lock entry says `workspace = true` and has no `commit` and no `hash`, and `agentica install` answers `in the workspace NAME@workspace` for it. A project outside the repository resolves the same dependency through the cache and `deps/` as usual, and a `[workspace]` table in a package of the cache or of `deps/` is ignored. A bad table is `PKG-MANIFEST-INVALID` at `workspace.repository`, `workspace.members` or `workspace.members[n]` (a member is written like a `subdir` and holds its own `agentica.toml`); a lock that disagrees with the workspace is `PKG-LOCK-STALE`.

A declared name comes before the `pkg/` library folders (`agc_libs/` too), so it hides a library of the same name there. A file of a package imports only the packages that its own `agentica.toml` declares.

A manifest that declares dependencies needs an `agentica.lock` beside it. The lock holds the exact commit and a hash of the `.agc` files of every package, direct or not. A build never downloads anything: it finds each package by its commit and checks its hash when an import first loads it.

The packages come only from `deps/<name>/` next to `agentica.toml`, one folder for each package of the lock that is not a workspace member, direct or not. `agentica install` writes them there and never changes the lock. A package that `deps/` lacks is `CHECK-IMPORT-PACKAGE`, and the help says to run `agentica install`. Commit `deps/` or ignore it as you like: the tool writes no `.gitignore` there, and a committed `deps/` needs no `agentica install` to build. A build hashes a package when an import first loads it, and the bytecode cache of `agentica FILE.agc` hashes only the files the program reads, so a new unused file in `deps/` is caught by `check` or `--no-cache`, not by a cached run. `agentica test` and `agentica symbol` skip `deps/` when they walk the project. Compiled programs are kept in `_build/`, which has its own `.gitignore`.

`agentica install` runs the system `git`, so your git config, SSH keys and credential helpers apply. For each package of the lock that is not in the download cache, `~/.cache/agentica/pkg/<host>/<owner>/<repo>/<commit>/` (on Windows, `%LOCALAPPDATA%\agentica\cache\pkg\`; `XDG_CACHE_HOME` replaces `~/.cache` when it is an absolute path), it fetches the tag (or the locked commit) without a checkout, checks that the commit is the locked one and that the hash of the copied `.agc` files is the locked hash, and puts the files in the cache, so a commit is never fetched twice. A package that is already there with the right hash is not fetched, and a cache that is full needs no `git` and no network. Then it writes every package of the lock into `deps/<name>/`, checking the hash again; a folder of `deps/` whose `.agc` files differ from the lock (an edited, added or missing file) is replaced by the locked files, a folder that already has the locked hash is left as it is, other files in it stay, and the folders of other names stay. The cache and the manifests are checked first, so a lock that fails those checks writes nothing to `deps/`; a failure in the middle of the copy (a full disk, say) leaves `deps/` partly updated, and running `agentica install` again finishes it. `deps/` must be a real folder, not a link (`PKG-SYMLINK`). Only the `.agc` files and the `agentica.toml` of the package are copied, each at most 1 MiB (16 MiB together), and two paths that differ only in case are refused. Git may ask for a password on the terminal, and each git read has a 5 minute deadline. If a tag now points to another commit, you get `PKG-TAG-MOVED`; if the files are not the locked ones, `PKG-HASH-MISMATCH`; if git fails, `PKG-FETCH`.

```sh
agentica install
```

`agentica add` and `agentica update` write the lock, so you do not write it by hand. `add` takes the local name, the `https://` URL and a tag (or a whole commit id with `--ref`), and `--subdir DIR` for a folder of the repository, fetches the package and the packages in its own `agentica.toml`, and writes `agentica.lock`, one new line of `[dependencies]` in `agentica.toml` (your comments and the rest of the file stay as they are) and `deps/`. `update` fetches the tag pins again, all of them or the one dependency you name, and takes the commit a tag points to now; a pin that is a commit does not move. It also repairs a lock that is missing or out of date after you edit the manifest. Both refresh `deps/` and remove the folder of a package that the lock no longer holds; if `deps/` cannot be written, the lock is saved already and the help says to run `agentica install` to write the locked packages into `deps/`. Both start `git` and may use the network. Nothing is written if a step before the lock fails, and the answer lists what was added, updated or removed.

```sh
agentica add sqlite https://github.com/owner/sqlite-ac --tag v1.2.0
agentica add postgres https://github.com/owner/packages --tag postgres-0.1.0 --subdir postgres
agentica update sqlite
```

Problems are reported with `PKG-` codes: a bad manifest or lock, a lock that does not match the manifest, one name with two sources, or a package file that changed, or a fetch that failed. A declared package that is not in `deps/` is `CHECK-IMPORT-PACKAGE`.

Import cycles are errors (`CHECK-IMPORT-CYCLE`), and so are missing files (`CHECK-IMPORT-IO`).
