---
title: Modules and imports
weight: 13
description: Split a program into files, export declarations and use the standard library.
---

## One file, one module

Each `.agc` file is a module. `export` makes a function, struct or enum
visible to other files. Everything else stays private.

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

Every file lists its declarations in the same order: the module doc and the imports, then `struct` and `enum` declarations, then `export def` functions, then private `def` functions. Types may come in any order among themselves. The order is only style, because a function can still call one declared later, but the checker enforces it so every file reads the same way.

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

`import` loads a file and gives it a name, the alias. Use the alias in front of
every name from that file.

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

Paths are relative to the importing file and leave out the `.agc` extension:
`"shapes"` loads `shapes.agc`. Aliases start with an uppercase letter.
Calling a private function is an error:

```agentica {expect="CHECK-IMPORT-NAME"}
import Shapes from "shapes"

def main() -> Void
  puts(Shapes.secret())
end
```

## Types and enums from a module

Imported types use the alias too: in annotations, in construction and in
patterns.

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

This works for functions, structs and enums. For an enum, import the enum, not its variants: its values and patterns keep the enum name in front.

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

An entry may rename with `as`. The new name keeps the case rule of what it names: types stay capitalized and functions stay lowercase (`CHECK-IMPORT-RENAME` otherwise). Renaming lets two modules that export the same name both be imported, and shortens long names:

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

An imported name cannot be the name of a declaration in the file, of an alias, of another imported name or of a builtin (`CHECK-REDEFINED-NAME`). Two lines may import from the same path, one with an alias and one with names, but one line does only one of the two. A module imported only by names has no alias.

Only the root file needs `main`. Imported files have no top-level code, so
importing a file never runs anything.

## The standard library

Paths that start with `std/` load the standard library that ships with
Agentica. `std/queue` is a first-in, first-out queue of strings:

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

Paths that start with `pkg/` load installed libraries. `import Tools from
"pkg/acme/tools"` looks for `acme/tools.agc` in `agc_libs/` next to the main program,
then in each directory listed in `AGENTICA_PATH`, then in
`~/.local/share/agentica/lib/`, `/usr/local/share/agentica/lib/` and
`/usr/share/agentica/lib/`.

Import cycles are errors (`CHECK-IMPORT-CYCLE`), and so are missing files
(`CHECK-IMPORT-IO`).
