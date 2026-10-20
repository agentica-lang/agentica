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
# struct, enum and type alias, in any order
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

A transparent type alias may be exported and imported in the same way. For example, `export type Names = List[String]` is used as `S.Names` or imported with `import {Names} from "status"`. It stands for `List[String]` everywhere; the alias does not provide a constructor or enum variants. A generic alias such as `export type Matrix[T] = List[List[T]]` works the same way: `S.Matrix[Int]`, or `Matrix[Int]` after `import {Matrix} from "status"`.

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

Paths that start with `pkg/` load installed libraries. `import Tools from "pkg/acme/tools"` looks for `acme/tools.agc` in `agc_libs/` next to the main program, then in each directory listed in `AGENTICA_PATH`, then in `~/.local/share/agentica/lib/`, `/usr/local/share/agentica/lib/` and `/usr/share/agentica/lib/`. On Windows, `AGENTICA_PATH` is separated by `;` (drive paths such as `C:\libs` are fine), the user directory is `%LOCALAPPDATA%\agentica\lib\`, and there are no system directories.

Import cycles are errors (`CHECK-IMPORT-CYCLE`), and so are missing files (`CHECK-IMPORT-IO`).
