---
title: Enums and case
weight: 11
description: Enums with and without payloads, generic enums and case pattern matching.
---

## Declare an enum

An enum is a type with a fixed set of variants. Write a variant with the enum
name in front.

```agentica
enum Color
  Red
  Green
  Blue
end

def main() -> Void
  c = Color.Green
  puts(c)
end
```

```output
Color.Green
```

## case on an enum

`case` runs the arm that matches. It must cover every variant, or end with `_`.

```agentica
enum Color
  Red
  Green
  Blue
end

def name(c: Color) -> String
  case c
    Color.Red -> return "red"
    Color.Green -> return "green"
    Color.Blue -> return "blue"
  end
end

def main() -> Void
  puts(name(Color.Blue))
end
```

```output
blue
```

A missing variant is a checker error, so you cannot forget a case:

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
enum Color
  Red
  Green
end

def main() -> Void
  case Color.Red
    Color.Red -> puts("red")
  end
end
```

## Variants with data

A variant can carry values. A pattern gives each value a name.

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
end

def area(s: Shape) -> Float
  case s
    Shape.Circle(r) -> return 3.14 * r * r
    Shape.Rect(w, h) -> return w * h
  end
end

def main() -> Void
  puts(area(Shape.Circle(1.0)))
  puts(area(Shape.Rect(2.0, 3.0)))
end
```

```output
3.14
6.0
```

Use `_` to ignore a value or every other variant:

```agentica
enum Event
  Click(Int, Int)
  Key(String)
  Quit
end

def main() -> Void
  events = [Event.Click(3, 4), Event.Key("q"), Event.Quit]
  for e in events
    case e
      Event.Click(x, _) -> puts("click at x=#{x}")
      _ -> puts("other: #{e}")
    end
  end
end
```

```output
click at x=3
other: Event.Key("q")
other: Event.Quit
```

## Generic enums

An enum can take a type parameter. `Option` is not built in, but it is easy to
write:

```agentica
enum Option[T]
  Some(T)
  None
end

def find_even(xs: List[Int]) -> Option[Int]
  for x in xs
    if x % 2 == 0
      return Option.Some(x)
    end
  end
  return Option.None
end

def main() -> Void
  case find_even([1, 3, 4])
    Option.Some(n) -> puts("found #{n}")
    Option.None -> puts("none")
  end
end
```

```output
found 4
```

## Enums are recursive

A variant may hold its own enum type, which makes trees and lists:

```agentica
enum Expr
  Num(Int)
  Add(Expr, Expr)
end

def eval(e: Expr) -> Int
  case e
    Expr.Num(n) -> return n
    Expr.Add(a, b) -> return eval(a) + eval(b)
  end
end

def main() -> Void
  puts(eval(Expr.Add(Expr.Num(2), Expr.Add(Expr.Num(3), Expr.Num(4)))))
end
```

```output
9
```

Patterns are one level deep: no nested patterns and no guards. Use a nested
`case` or an `if` inside the arm.
