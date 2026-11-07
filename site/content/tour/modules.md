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

An import alias that the file never uses is an error at the alias (`CHECK-UNUSED-IMPORT`); remove the import. A regex literal counts as a use of the `std/regex` import and a `<<~EAG` template as a use of the `std/eag` import. The query commands such as `type-at` and `symbol` do not report it in the file they are asked about (the files it imports keep the rule). An alias written without a member, such as `x: Shapes`, is `CHECK-IMPORT-NAME`. Unused names of an import list are not reported.

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

The local name does not have to match the URL, so moving a repository changes only its `git` line. A declared name comes before the `pkg/` library folders (`agc_libs/` too), and a file of a package imports only the packages that its own `agentica.toml` declares.

One repository can hold several packages, each in its own folder. Name the folder with `subdir`, a relative path of plain folder names, and use prefixed tags for the versions:

```toml
[dependencies]
sqlite = { git = "https://github.com/owner/packages", tag = "sqlite-0.1.0", subdir = "sqlite" }
postgres = { git = "https://github.com/owner/packages", tag = "postgres-0.1.0", subdir = "postgres" }
```

The folder is the package: it has its own `agentica.toml`, its relative imports cannot leave it, and its hash covers only its files.

A repository of packages can also be a workspace, so that you can develop one package against another without tagging either. The `agentica.toml` at the root of the repository lists the repository and its member folders:

```toml
[workspace]
repository = "https://github.com/owner/packages"
members = ["sqlite", "postgres"]
```

In a project that is the root or a member, a dependency whose `git` is the `repository` and whose `subdir` is a member is read from the member's folder: it is not fetched, not copied to `deps/`, and an edit there is seen by the next build. A project outside the repository resolves it through the cache and `deps/` as usual.

The root `agentica.toml` can also point a dependency at a folder on your machine, with `path`, relative to the manifest or absolute, and can force one source for a name everywhere in the tree, with `override = true`:

```toml
[dependencies]
channels = { git = "https://github.com/owner/channels", tag = "v1" }
bond = { git = "https://github.com/owner/bond", tag = "0.8.0", override = true }
```

A `path` dependency (`bond = { path = "../bond" }`) is not fetched, not cached and not copied to `deps/`: the build reads the folder, so an edit there is seen by the next build. The folder needs an `agentica.toml`, and the lock records the `path` with no commit and no hash. Without `override`, two sources for one name anywhere in the tree are `PKG-SOURCE-CONFLICT`. With it, the root's source wins for every package that asks for that name (here `channels` may ask for another `bond` tag), and `install`, `add` and `update` print an `overridden` line for each such package. `override = true` works with `path`, to try a local copy of a transitive dependency. Both keys are for the root project only: in the `agentica.toml` of a package they are `PKG-ROOT-ONLY`, since a package must be publishable.

A package can use a native library from its `extern` blocks (see [Native code](/library/io-and-system/native/)). Its `agentica.toml` names the library for each system it exists on (`linux`, `macos` or `windows`), as a `file` in the package's `native/` folder, as a `system` name that the system loader looks up (or an absolute path, or a list of them), or as a download pinned per system in `[[native-artifact]]`:

```toml
[native.sqlite3]
linux = { system = "libsqlite3.so.0" }
macos = { system = "libsqlite3.dylib" }
windows = { file = "native/windows/sqlite3.dll" }
```

A `system` list gives candidates in order of preference, as bare names or absolute paths: `macos = { system = ["libpq.5.dylib", "/opt/homebrew/opt/libpq/lib/libpq.5.dylib"] }`. The first absolute path that is a file wins, else the first bare name, else the first path. In the files of that package, `extern "sqlite3"` means the entry of the system the program runs on. A package with no entry for your system is `PKG-NATIVE-PLATFORM` where a file uses the library.

A [native module](/library/io-and-system/native/modules/) can instead be built from its C sources in `native/`, with a `build` table, which wins over the system entries:

```toml
[native.stats]
build = { sources = ["native/stats.c"], defines = ["NDEBUG"], libs = ["m"] }
```

A run, `compile`, `test` and `install` run your C compiler (`cc`, `gcc` on Windows, or the words of `CC`, split at spaces with no quoting) on the C of `native/`. A run builds a library when a file first uses it, into the package cache, and prints `built native stats: PATH` on stderr; `install` builds those of the project, its workspace members and its `path` dependencies, but not those of fetched packages, so installing one needs no compiler. A fetched package is compiled from a private copy of the files of its `native/` that the hash of its row in `agentica.lock` covers, checked against that hash, so what is built is the code of the locked commit: a dotfile there is left out, a header outside `native/` is not found, and a changed copy is `PKG-HASH-MISMATCH` (run `agentica install` to put the locked files back). `check` never builds (a changed copy is still `PKG-HASH-MISMATCH`), and neither does a command under any `--deny-*` flag or `--sandbox`: the run is refused (`RUNTIME-NATIVE-DENIED`) and `compile` is `PKG-NATIVE-BUILD`. The manifest gives only sources in `native/`, defines and library names: it names no compiler and no flag. The cache key covers the files of `native/` (hidden ones too), the table, the compiler and its version, and `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` and `LIBRARY_PATH`. Keep your own headers under `native/`: system headers, installed libraries and the rest of the environment are not in the key, so to build again after they change, remove the entry or change a file under `native/`. The bytecode cache sees an edit or a new file in `native/`. A failed build is `PKG-NATIVE-BUILD`.

The optional `[style]` table of `agentica.toml` applies to the files below its folder that have no nearer `agentica.toml`. Libraries are not checked. With `max_line_width = N`, a line of more than N characters makes `agentica check` report `CHECK-LINE-TOO-LONG`; `agentica fmt` lays out in N columns (119 without the key). With `blank_line_after_end = true`, a line that holds only `end` needs an empty line after it, or `agentica check` reports `CHECK-BLANK-LINE-AFTER-END`; the next line may instead start with `end`, `else`, `elsif`, `)`, `]`, `}` or `.name`.

A manifest that declares dependencies needs an `agentica.lock` beside it. The lock holds the exact commit and a hash of the `.agc` files of every package, direct or not. A build never downloads anything: it reads each package from `deps/<name>/` next to `agentica.toml` and checks its hash when an import first loads it. A package that `deps/` lacks is `CHECK-IMPORT-PACKAGE`, and the help says to run `agentica install`. Commit `deps/` or ignore it as you like.

Three commands keep `deps/` and the lock. All of them run the system `git`, so your git config, SSH keys and credential helpers apply.

- `agentica install` fetches each package of the lock that is not in the download cache, checks its commit and hash against the lock, and writes every package into `deps/<name>/`. It never changes the lock. A tag that now points to another commit is `PKG-TAG-MOVED`, files that are not the locked ones are `PKG-HASH-MISMATCH`, and a git failure is `PKG-FETCH`.
- `agentica add` takes the local name, the `https://` URL and a tag (or a whole commit id with `--ref`), and `--subdir DIR` for a folder of the repository. It fetches the package and the packages in its own `agentica.toml`, and writes `agentica.lock`, one new line of `[dependencies]` in `agentica.toml` (your comments stay) and `deps/`.
- `agentica update` fetches the tag pins again, all of them or the one dependency you name; a pin that is a commit does not move. It also repairs a lock that is missing or out of date after you edit the manifest.

```sh
agentica install
agentica add sqlite https://github.com/owner/sqlite-ac --tag v1.2.0
agentica add postgres https://github.com/owner/packages --tag postgres-0.1.0 --subdir postgres
agentica update sqlite
```

Problems are reported with `PKG-` codes: a bad manifest or lock, a lock that does not match the manifest, one name with two sources, a package file that changed, or a failed fetch. The full rules, with every limit and code, are in the [modules reference](/reference/modules/).
