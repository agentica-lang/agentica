---
title: Values and types
weight: 1
description: The basic types, how to print values, and the program shape.
---

## A program

A program is a file of declarations. It has one `main` function, and running the file calls it. Blocks end with `end`.

```agentica
def main() -> Void
  puts("one line")
  print("no new line, ")
  puts("then one")
end
```

```output
one line
no new line, then one
```

`#` starts a comment that runs to the end of the line. Code cannot sit at the top of the file outside a function.

A `##` line is a doc comment, placed directly above a `def`, `struct`, `enum`, field or variant. It is Markdown and does not change the program.

```agentica
# An ordinary comment: nothing reads it.
## Adds two numbers.
def add(a: Int, b: Int) -> Int
  return a + b
end

def main() -> Void
  puts(add(2, 3)) # a note after code
end
```

```output
5
```

A `##` block at the top of a file, followed by a blank line, documents the module. A `##` block that is not directly above its target is `PARSE-DETACHED-DOC`.

## Basic types

Every value has a type. The checker knows the type of every expression before the program runs.

| Type | Values |
|---|---|
| `Int` | whole numbers, 64 bits: `42`, `-7` |
| `Float` | decimal numbers: `3.14`, `0.5` |
| `Bool` | `true` and `false` |
| `String` | text: `"hello"` |
| `Nil` | the single value `nil` |

```agentica
def main() -> Void
  puts(42)
  puts(3.14)
  puts(true)
  puts("hello")
  puts(nil)
end
```

```output
42
3.14
true
hello
nil
```

There are also lists, maps, structs, enums and results. Later pages show them.

`type Names = List[String]` gives a long type a short name. It is not a new type. Aliases cannot be constructors or enum patterns, and cycles are rejected.

An alias can take type parameters. `Matrix[Int]` means exactly `List[List[Int]]`, and every parameter needs an argument:

```agentica
type Matrix[T] = List[List[T]]

def main() -> Void
  rows: Matrix[Int] = [[1, 2], [3]]
  plain: List[List[Int]] = rows
  puts(plain.size)
end
```

```output
2
```

## Printing values

`puts` prints any value. Strings print as they are. Other values print in a short, readable form:

```agentica
def main() -> Void
  puts([1, 2, 3])
  puts({"a": 1})
  puts(ok(5))
end
```

```output
[1, 2, 3]
{"a": 1}
ok(5)
```

## to_s and inspect

Every data value has `to_s`, the text that `puts` prints. A function, a task or a handle, such as a `Listener`, has none: `f.to_s` is `CHECK-UNKNOWN-METHOD`. `inspect` is the debug form: strings keep their quotes.

```agentica
def main() -> Void
  puts(7.to_s)
  puts("hi".to_s)
  puts("hi".inspect)
  puts([1, 2].to_s)
end
```

```output
7
hi
"hi"
[1, 2]
```

`IO.inspect` prints the debug form and gives the value back, so you can put it in the middle of an expression:

```agentica
def main() -> Void
  total = IO.inspect(2 + 3) * 10
  puts(total)
end
```

```output
5
50
```

## No implicit conversion

Types never change on their own. `1 + 2.5` is an error: convert first.

```agentica
def main() -> Void
  puts(1.to_f + 2.5)
  puts("n = " + 4.to_s)
end
```

```output
3.5
n = 4
```

## No truthiness

`if` needs a `Bool`. `0`, `""` and `nil` are not false; using them as a condition is a checker error.

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  if 1
    puts("never")
  end
end
```

## Values never change

Values are immutable. A method gives a new value and leaves the old one as it was. Assign the result to keep it.

```agentica
def main() -> Void
  xs = [1, 2]
  ys = xs.push(3)
  puts(xs)
  puts(ys)
end
```

```output
[1, 2]
[1, 2, 3]
```
