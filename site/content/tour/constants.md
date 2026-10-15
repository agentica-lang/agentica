---
title: Constants
weight: 14
description: Name a fixed value once at the top of a file, build a table once and share it between files.
---

## A value fixed for the run

A constant is a name in capitals at the top level of a file, with a value after `=`. It never changes, and any function of the file can read it:

```agentica
SECONDS_PER_DAY = 24 * 60 * 60
GREETING = "hello"

def main() -> Void
  puts("#{GREETING}: #{SECONDS_PER_DAY}")
end
```

```output
hello: 86400
```

The name is capital letters, digits and `_`, at least two characters (`LIMIT`, `MAX_DEPTH`). Another spelling is `PARSE-CONSTANT-NAME`, and the help says which name to use:

```agentica {expect="PARSE-CONSTANT-NAME"}
MaxDepth = 8

def main() -> Void
  puts(MaxDepth)
end
```

Constants come right after the imports of a file, before types and functions. Constants follow each other with no blank line between them. A type can be written as in a binding (`RATIO: Float = 1.5`), which also gives `[]` and `{}` their type.

## Build a table once

A function that builds a list or a map runs the code each time it is called. A constant is built once, before `main`, and every read gives the same value:

```agentica
PRICES = {"tea": 3, "cocoa": 5}
FRUITS = Set.new(["kiwi", "apple"])

def kind(name: String) -> String
  if FRUITS.include?(name)
    return "fruit"
  end
  return "drink"
end

def main() -> Void
  puts(PRICES.get("cocoa", 0))
  puts(kind("kiwi") + " " + kind("tea"))
end
```

```output
5
fruit drink
```

A constant is a value, so everything that works on a value works on it: `PRICES.get(...)`, `PRICES["tea"]`, `FRUITS.size`, `"#{PRICES}"`. A constant may read another one, declared above or below it. A loop (`A` reads `B` and `B` reads `A`) is `CHECK-CONSTANT-CYCLE`.

## What a constant may hold

The value is built from literals, lists, maps, sets, struct and enum values, operators, other constants and builtins that have no effects (`Set.new`, `map`, `reduce`, `keys` and the rest). A call of one of your own functions, a function value, a `while` loop and a builtin that reads or writes the world are `CHECK-CONSTANT-EXPRESSION`:

```agentica {expect="CHECK-CONSTANT-EXPRESSION"}
LINE = IO.gets!()

def main() -> Void
  puts(LINE)
end
```

The value has a data type: numbers, text, lists, maps, sets, ranges, `Result`, structs and enums of those. A channel, a task or a function is `CHECK-CONSTANT-TYPE`. Nothing assigns to a constant, so `LIMIT = 2` inside a function is `PARSE-INVALID-ASSIGNMENT-TARGET`.

## Share a constant between files

`export` makes a constant visible, and the importing file brings it in by name, like a function or a struct:

```agentica {file="limits.agc"}
export MAX = 100
export NAMES = ["x", "y"]
```

```agentica
import {MAX, NAMES as LABELS} from "limits"

def main() -> Void
  puts(MAX)
  puts(LABELS.size)
end
```

```output
100
2
```

A renamed constant is renamed to another constant name. A constant is not reached through the alias: `Limits.MAX` is `CHECK-IMPORT-NAME`, and the help says to write `import {MAX} from "limits"`.
