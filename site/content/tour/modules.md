---
title: Modules and imports
weight: 13
description: Split a program into files, make declarations public and use the standard library.
---

## One file, one module

Each `.agc` file is a module. Every declaration is public, so other files can use it, except the ones after a `private` line, which stay private to the file.

Save this as `shapes.agc`:

```agentica {file="shapes.agc"}
struct Square
  side: Int
end

def area(s: Square) -> Int = s.side * s.side

private

def secret() -> Int = 42
```

`private` stands alone on its line, with a blank line before and after it, once per file. Imports are never public. A file without `private` is public as a whole. `export` before a declaration is an error (`PARSE-UNEXPECTED-TOKEN`); only `export Alias.name` is left, to re-export a name.

## File layout

Each file lists its declarations in this order (`CHECK-DECL-ORDER` otherwise):

```text
# module doc and imports
# the public part:
#   constants and re-exports (see Constants and Re-exports)
#   struct, enum, type alias, module block and extern block with a resource or a struct (its defs too), in any order
#   def
# private
# the private part, in the same order: constants, then types and blocks, then def
```

A blank line goes before each declaration after the first.

A struct after a private function is `CHECK-DECL-ORDER`:

```agentica {expect="CHECK-DECL-ORDER"}
def main() -> Void
  puts(secret())
end

private

def secret() -> Int = 42

struct Box
  value: Int
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
enum Status
  Active
  Banned(String)
end
```

```agentica
import S from "status"

def show(s: S.Status) -> String
  case s
    S.Status.Active -> "active"
    S.Status.Banned(why) -> "banned: #{why}"
  end
end

def main() -> Void
  puts(show(S.Status.Banned("spam")))
end
```

```output
banned: spam
```

A transparent type alias may be public and imported in the same way. For example, `type Names = List[String]` is used as `S.Names` or imported with `import {Names} from "status"`. A generic alias such as `type Matrix[T] = List[List[T]]` works the same way: `S.Matrix[Int]`, or `Matrix[Int]` after `import {Matrix} from "status"`.

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
    Status.Active -> "active"
    Status.Banned(why) -> "banned: #{why}"
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

## Module blocks

`module Name ... end` groups declarations under a name, so one file can hold several modules. A block holds constants, structs, enums, type aliases and functions with the layout rules of a file, its own `private` line included: what is above it is visible outside the block, and a block with no `private` is public as a whole. Save this as `agents.agc`:

```agentica {file="agents.agc"}
module Counter
  LIMIT = 100

  enum Msg
    Add(Int)
    Get
  end

  def start(initial: Int) -> Int = step(initial, Msg.Add(1))

  private

  def step(count: Int, msg: Msg) -> Int
    case msg
      Msg.Add(n) -> count + n
      Msg.Get -> count
    end
  end
end

module Greeter
  def hello(name: String) -> String = "hello #{name}, up to #{Counter.LIMIT}"
end
```

Inside a block its own names are bare, and the imports, top-level names and other blocks of the file are visible too. Outside, write the block's name first. `import {Counter} from "agents"` imports a public block like an alias, and `import Agents from "agents"` reads it as `Agents.Counter`:

```agentica
import {Counter, Greeter} from "agents"
import Agents from "agents"

def main() -> Void
  puts(Counter.start(1))
  puts(Greeter.hello("Ana"))
  msg = Agents.Counter.Msg.Add(2)
  puts(Agents.Counter.start(0) + Counter.LIMIT)
  puts(msg == Counter.Msg.Add(2))
end
```

```output
2
hello Ana, up to 100
101
true
```

A private name of a block is `CHECK-IMPORT-NAME`, as a private name of a file:

```agentica {expect="CHECK-IMPORT-NAME"}
import {Counter} from "agents"

def main() -> Void
  puts(Counter.step(1, Counter.Msg.Get))
end
```

The name of a block follows the rules of an import alias (`CHECK-REDEFINED-NAME`), a block sits at the top level with the structs and enums (a block inside a block is `PARSE-NESTED-MODULE`), and it holds no import, re-export or extern block. A block after the file's `private` line is private to its file. Inside a block, a name the file already declares or imports is `CHECK-SHADOWED-NAME` (one name means one thing), and `main` is `CHECK-MAIN`; two blocks may each have a `start`.

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

Paths that start with `pkg/` load installed libraries: `import Tools from "pkg/acme/tools"` looks for `acme/tools.agc` in `agc_libs/` next to the main program, then in the folders of `AGENTICA_PATH` and the user and system library folders ([search order](/reference/modules/#standard-library-and-external-libraries)).

## Packages

A package is a git repository of `.agc` files. A project with an `agentica.toml` next to its main file, or in a folder above it, can import the packages the manifest declares. Each dependency has a local name and one pin, a `tag`, a `ref` (a commit) or a `version` (a requirement over the tags):

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

`agentica init [NAME]` starts a project in the working folder, with an `agentica.toml` and a `main.agc` that prints `Hello, world!`. It never changes an existing manifest.

A manifest that declares dependencies needs an `agentica.lock` beside it, with the exact commit and a hash of every package. A build never downloads anything: it reads each package from `deps/<name>/` and checks its hash. Three commands keep `deps/` and the lock, through the system `git`:

- `agentica install` fetches what the lock names into `deps/`; it never changes the lock.
- `agentica add NAME URL --tag TAG` (or `--ref COMMIT`, `--version REQUIREMENT`, `--subdir DIR`, `--workspace`) adds a dependency to `agentica.toml`, the lock and `deps/`. `OWNER/REPO` in place of the URL is `https://github.com/OWNER/REPO`, and the files store the full URL; another source is `PKG-SOURCE-INVALID`. A tag `NAME-X.Y.Z` with no `--subdir` takes the folder `NAME` of the repository when the package is there and not at its root.
- `agentica update [NAME]` fetches the tag pins again, takes the highest tag that satisfies each `version`, and repairs a lock that is out of date.
- `version = "~> 0.8"` takes the highest tag `X.Y.Z` or `vX.Y.Z` (`NAME-X.Y.Z` for a `subdir`) that satisfies a requirement as RubyGems and Mix read it: terms joined by commas with `~>`, `>=`, `>`, `<=`, `<` and `==`, where `~> 0.8` means `>= 0.8.0, < 1.0.0` and `~> 0.8.1` means `>= 0.8.1, < 0.9.0`. The lock keeps the chosen `tag` and the `version`, so a build and `install` stay exact and offline; only `add` and `update` list the tags. A requirement that no tag satisfies is `PKG-VERSION-UNSATISFIED`. A name has one requirement in the whole tree for now.

```sh
agentica install
agentica add sqlite https://github.com/owner/sqlite-ac --tag v1.2.0
agentica add jobs agentica-lang/packages --tag jobs-0.1.0
agentica update sqlite
```

A repository of packages that has a `[workspace]` table in its root `agentica.toml` can be one dependency, with `workspace = true`. The project locks and installs every member, and imports one as `pkg/NAME/MEMBER/MODULE`, so the names of the members never clash with the names the project uses:

```toml
[dependencies]
finn = { git = "https://github.com/owner/finn", tag = "finn-1", workspace = true }
```

```text
import Core from "pkg/finn/core/agent"
```

Inside the workspace, a member that depends on another member of the same repository gets the one of the workspace, at the pin of the workspace, whatever pin it writes.

A dependency that only the tests use, such as a property-testing package, takes `group = "test"` (`agentica add NAME URL --tag TAG --group test` writes it). The project locks and installs it, but only its `*_test.agc` files and its step program import it; any other program that imports it stops with `CHECK-IMPORT-PACKAGE`. A project that depends on your package never fetches it.

```toml
[dependencies]
prop = { git = "https://github.com/owner/prop", tag = "v1.0.0", group = "test" }
```

A manifest may name the oldest Agentica it needs, `agentica = "0.31.0"`; an older Agentica stops `install`, `check`, `run` and `test` with `PKG-AGENTICA-TOO-OLD`.

Problems are reported with `PKG-` codes. Workspaces, `path` and `override` dependencies, native libraries and modules built from C, the `[style]` and `[tool.NAME]` tables, and every limit and code are in the [modules reference](/reference/modules/); native code is in [Native code](/library/io-and-system/native/).
