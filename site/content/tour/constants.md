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

A name is capital letters, digits and `_`, at least two characters (`LIMIT`, `MAX_DEPTH`). Another spelling is `PARSE-CONSTANT-NAME`:

```agentica {expect="PARSE-CONSTANT-NAME"}
MaxDepth = 8

def main() -> Void
  puts(MaxDepth)
end
```

- Constants come after the imports and before types and functions, with no blank line between them.
- Give a type as in a binding (`RATIO: Float = 1.5`). It also types `[]` and `{}`.

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

- A constant works like any value: `PRICES.get(...)`, `PRICES["tea"]`, `FRUITS.size`.
- A constant may read another one, above or below it. A loop is `CHECK-CONSTANT-CYCLE`.

## When a constant is built

- A literal such as `WIDTH = 8` is part of the program.
- Any other constant is built once, before `main`, and only if a function that `main` can reach reads it. An unread constant never runs.
- If an initializer fails, the program stops before `main` prints anything:

```agentica {expect="RUNTIME-INDEX-OUT-OF-RANGE"}
BAD = [1][5]

def main() -> Void
  puts("never printed")
  puts(BAD)
end
```

The stack trace names `BAD`.

## What a constant may hold

- It may hold literals, lists, maps, sets, struct and enum values, operators, other constants and builtins without effects (`Set.new`, `map`, `reduce`, ...).
- A call of your own function, a function value, a `while` loop or a builtin that reads or writes the world is `CHECK-CONSTANT-EXPRESSION`:

```agentica {expect="CHECK-CONSTANT-EXPRESSION"}
LINE = IO.gets!()

def main() -> Void
  puts(LINE)
end
```

- Its type is numbers, text, lists, maps, sets, ranges, `Result`, or structs and enums of those. A channel, task or function is `CHECK-CONSTANT-TYPE`.
- Nothing assigns to a constant: `LIMIT = 2` in a function is `PARSE-INVALID-ASSIGNMENT-TARGET`.

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

A file that imports the module under an alias reads the constant as `Limits.MAX`, like an exported function:

```agentica
import Limits from "limits"

def main() -> Void
  puts(Limits.MAX)
  puts(Limits.NAMES.size)
end
```

```output
100
2
```

A constant the module keeps private is `CHECK-IMPORT-NAME`, as for a function.
