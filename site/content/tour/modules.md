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
import "shapes" as Shapes

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
import "shapes" as Shapes

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
import "status" as S

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

Only the root file needs `main`. Imported files have no top-level code, so
importing a file never runs anything.

## The standard library

Paths that start with `std/` load the standard library that ships with
Agentica. `std/queue` is a first-in, first-out queue of strings:

```agentica
import "std/queue" as Queue

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

Paths that start with `pkg/` load installed libraries. `import "pkg/acme/tools"
as Tools` looks for `acme/tools.agc` in `agc_libs/` next to the main program,
then in each directory listed in `AGENTICA_PATH`, then in
`~/.local/share/agentica/lib/`, `/usr/local/share/agentica/lib/` and
`/usr/share/agentica/lib/`.

Import cycles are errors (`CHECK-IMPORT-CYCLE`), and so are missing files
(`CHECK-IMPORT-IO`).
