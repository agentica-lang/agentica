---
title: Enums and case
weight: 11
description: Enums with and without payloads, generic enums and case pattern matching.
---

## Declare an enum

An enum is a type with a fixed set of variants. Write a variant with the enum name in front.

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
    Color.Red -> "red"
    Color.Green -> "green"
    Color.Blue -> "blue"
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
    Shape.Circle(r) -> 3.14 * r * r
    Shape.Rect(w, h) -> w * h
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

`_` drops a value (see [Variables](/tour/variables/)) or matches every other variant:

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

## A case that gives a value

A `case` gives a value in three places: the right side of an assignment, after `return`, and the last line of a block. Everywhere else it is a statement, so `puts(case ...)` and `1 + case ...` are errors.

Each arm ends with an expression, which is the value of the arm. An arm may have more lines before it.

```agentica
enum Kind
  Big
  Small
end

def label(kind: Kind) -> String
  return case kind
    Kind.Big -> "big"
    Kind.Small -> "small"
  end
end

def main() -> Void
  r: Result[Int] = ok(3)
  text = case r
    ok(n) -> "got #{n}"
    error(message) -> "failed: #{message}"
  end

  puts(text)

  size = case text
    "got 3" ->
      base = 2
      base + 1
    _ -> 0
  end

  puts(size)

  puts(label(Kind.Small))
  numbers = [Kind.Big, Kind.Small].map do |kind|
    case kind
      Kind.Big -> 1
      Kind.Small -> 2
    end
  end

  puts(numbers)
end
```

```output
got 3
3
small
[1, 2]
```

All the arms have one type, and the case must cover every variant, or end with `_`. The type is the annotation of the assignment, else the type of the first arm, so write `x: Result[Int] = case ...` when the first arm is `error(...)`, `[]` or `none`. An arm that ends with `return`, `next` or `break` has no value (`CHECK-CASE-ARM-VALUE`). A mismatch is `CHECK-TYPE-MISMATCH` at the last expression of the arm:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  text = case 1
    1 -> "one"
    _ -> 2
  end

  puts(text)
end
```

## Generic enums

An enum can take a type parameter. For a value that may be missing, use the built-in [Optional](/library/data-structures/optional/), not your own enum.

```agentica
enum Change[T]
  Added(T)
  Removed(T)
end

def describe(change: Change[Int]) -> String
  case change
    Change.Added(n) -> "+#{n}"
    Change.Removed(n) -> "-#{n}"
  end
end

def main() -> Void
  puts(describe(Change.Added(4)))
  puts(describe(Change.Removed(2)))
end
```

```output
+4
-2
```

## Enums are recursive

A variant can hold its own enum type, as in a tree:

```agentica
enum Expr
  Num(Int)
  Add(Expr, Expr)
end

def eval(e: Expr) -> Int
  case e
    Expr.Num(n) -> n
    Expr.Add(a, b) -> eval(a) + eval(b)
  end
end

def main() -> Void
  puts(eval(Expr.Add(Expr.Num(2), Expr.Add(Expr.Num(3), Expr.Num(4)))))
end
```

```output
9
```

## Guards

An arm can carry a guard: `pattern if condition ->`. The condition is a Bool and can use the names of the pattern. If it is false, `case` goes on with the next arm.

```agentica
enum Shape
  Circle(Int)
  Rect(Int, Int)
end

def size(s: Shape) -> String
  case s
    Shape.Circle(r) if r > 100 -> "big circle"
    Shape.Circle(_) -> "circle"
    Shape.Rect(w, h) if w == h -> "square"
    Shape.Rect(_, _) -> "rect"
  end
end

def main() -> Void
  puts(size(Shape.Circle(500)))
  puts(size(Shape.Rect(2, 2)))
  puts(size(Shape.Rect(2, 3)))
end
```

```output
big circle
square
rect
```

A guarded arm may fail, so it never covers a variant. The unguarded arm after it does, and the same pattern may come again.

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
def main() -> Void
  case Result.Ok(4)
    ok(n) if n > 0 -> puts("positive")
    error(_) -> puts("failed")
  end
end
```

## Several patterns in one arm

Separate patterns with commas to share one arm. The arm runs when any of them matches. Such an arm binds no names: write `_` in the payload positions.

```agentica
def ttl?(option: String) -> Bool
  case option
    "ex", "px" -> true
    _ -> false
  end
end

def main() -> Void
  puts(ttl?("px"))
  puts(ttl?("nx"))
end
```

```output
true
false
```

## Patterns inside patterns

In a payload position, a pattern can be a literal (also a negative number), a name, `_`, or another variant, `ok(...)`, `error(...)`, `some(...)` or `none`, at any depth.

```agentica
def describe(r: Result[Optional[Int]]) -> String
  case r
    ok(some(0)) -> "zero"
    ok(some(n)) if n < 0 -> "negative #{n}"
    ok(some(n)) -> "value #{n}"
    ok(_) -> "none"
    error("timeout") -> "timed out"
    error(_) -> "failed"
  end
end

def main() -> Void
  puts(describe(ok(some(-3))))
  puts(describe(ok(none)))
  puts(describe(error("timeout")))
end
```

```output
negative -3
none
timed out
```

An unguarded arm whose positions are only names or `_` covers its variant. Any other arm may fail, so end with `ok(_)`, a variant with `_` positions, or `_`.

The payload of your own variant can be an [Optional](/library/data-structures/optional/), and the same patterns apply:

```agentica
enum Reading
  Value(Optional[Int])
  Missing
end

def label(r: Reading) -> String
  case r
    Reading.Value(some(0)) -> "zero"
    Reading.Value(some(n)) -> "value #{n}"
    Reading.Value(_) -> "no value"
    Reading.Missing -> "missing"
  end
end

def main() -> Void
  puts(label(Reading.Value(some(0))))
  puts(label(Reading.Value(some(5))))
  puts(label(Reading.Value(none)))
  puts(label(Reading.Missing))
end
```

```output
zero
value 5
no value
missing
```

Here `some(n)` and `none` are both listed, but each arm has a variant inside, so neither covers `Reading.Value`. The case is not exhaustive until you add `Reading.Value(_)` or `_`, or use one arm with only a name, `Reading.Value(opt)`, and match `opt` inside it.

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
enum Reading
  Value(Optional[Int])
  Missing
end

def main() -> Void
  case Reading.Missing
    Reading.Value(some(n)) -> puts("value #{n}")
    Reading.Value(none) -> puts("no value")
    Reading.Missing -> puts("missing")
  end
end
```
