---
title: Optional
weight: 8
description: A value that may be missing, with some and none.
---

`Optional[T]` is `some(value)` or `none`. Use it for a value that may be missing: a struct field, a parameter, a return, a list or map item. `map.get(key)` and `text.index_of(part)` give one.

```agentica
struct User
  name: String
  age: Optional[Int]
end

def main() -> Void
  users = [User(name: "Ana", age: some(31)), User(name: "Bo", age: none)]
  for user in users
    case user.age
      some(n) -> puts("#{user.name} is #{n}")
      none -> puts("#{user.name} gave no age")
    end
  end
end
```

```output
Ana is 31
Bo gave no age
```

A `case` needs both arms, `some(n) ->` and `none ->`, or a final `_`. An arm with a literal inside, such as `some(0) ->`, may fail, so it covers nothing: add `some(n) ->` or `_` after it. [Patterns inside patterns](/tour/enums-and-case/#patterns-inside-patterns) shows an Optional in a user enum or a `Result`. `==` compares two Optionals whose items have `==`: `age == none`, `age == some(31)`. An Optional prints as `some(31)` or `none`. A field or parameter may default to `none`: `port: Optional[Int] = none`. In [JSON](/library/text-and-data/json/#optional-values), `none` is `null` (a missing key when decoding) and `some(x)` is `x`.

## Fields, parameters, items and generics

`Optional[T]` goes wherever a type does, `T` may be a type parameter, and Optionals nest. A parameter or field defaults to `none`, and a caller leaves it out or passes `some(x)`.

```agentica
struct Config
  host: String
  port: Optional[Int] = none
end

struct Box[T]
  item: Optional[T]
end

def greet(name: String, title: Optional[String] = none) -> String
  return "#{title.unwrap_or("Mx")} #{name}"
end

def first_or_none[T](xs: List[T]) -> Optional[T]
  if xs.length == 0
    return none
  end

  return some(xs[0])
end

def main() -> Void
  puts(Config(host: "localhost"))
  puts(Box(item: some(3)))
  puts(greet("Ana"))
  puts(greet("Ana", some("Dr")))
  puts(first_or_none(["a", "b"]))
  empty: List[Int] = []
  puts(first_or_none(empty))
  scores: Map[String, Optional[Int]] = {"ana": some(9), "bo": none}
  items: List[Optional[Int]] = [some(1), none, some(3)]
  puts(scores)
  puts(items.reduce(0) do |sum, o| sum + o.unwrap_or(0) end)
end
```

```output
Config(host: "localhost", port: none)
Box(item: some(3))
Mx Ana
Dr Ana
some("a")
none
{"ana": some(9), "bo": none}
4
```

## Lookups

`map.get(key)` and `text.index_of(part)` give an Optional: `some` when the key or the text is there, `none` when it is not. Pick the way to read it: `unwrap_or` for a default, `case` to act on each side, `unwrap!` only when `none` would be a bug.

```agentica
def main() -> Void
  stock = {"apple": 3, "pear": 0}
  puts(stock.get("apple").unwrap_or(0))
  puts(stock.get("kiwi").unwrap_or(0))
  case "hello world".index_of("wor")
    some(i) -> puts("found at #{i}")
    none -> puts("not found")
  end
end
```

```output
3
0
found at 6
```

## some

```text
some(value: T) -> Optional[T]
```

```agentica
def main() -> Void
  puts(some(3))
  puts(some("yes"))
end
```

```output
some(3)
some("yes")
```

## none

```text
none -> Optional[T]
```

The type comes from an annotation, a return type, a parameter or a field. A bare `x = none` is `CHECK-OPTIONAL-TYPE`.

```agentica
def find(names: List[String], wanted: String) -> Optional[Int]
  index = 0
  for name in names
    if name == wanted
      return some(index)
    end
    index += 1
  end
  return none
end

def main() -> Void
  puts(find(["a", "b"], "b"))
  puts(find(["a", "b"], "z"))
end
```

```output
some(1)
none
```

## Optional.unwrap_or

```text
Optional.unwrap_or(o: Optional[T], default: T) -> T
```

Gives the value, or the default for `none`. The default is always computed.

```agentica
def main() -> Void
  age: Optional[Int] = none
  puts(age.unwrap_or(0))
  puts(some(7).unwrap_or(0))
end
```

```output
0
7
```

## Optional.unwrap!

```text
Optional.unwrap!(o: Optional[T]) -> T
```

Gives the value, or stops the program with `RUNTIME-UNWRAP-NONE`.

```agentica
def main() -> Void
  puts(some(5).unwrap! * 2)
end
```

```output
10
```

## Optional.map

```text
Optional.map(o: Optional[T], f: Fn[T, U]) -> Optional[U]
```

Gives `some` of the block's value, or `none` without calling the block.

```agentica
def main() -> Void
  age: Optional[Int] = none
  puts(some(20).map do |n| n + 1 end)
  puts(age.map do |n| n + 1 end)
end
```

```output
some(21)
none
```

## Optional.some? and Optional.none?

```text
Optional.some?(o: Optional[T]) -> Bool
Optional.none?(o: Optional[T]) -> Bool
```

```agentica
def main() -> Void
  age: Optional[Int] = none
  puts(some(1).some?)
  puts(age.none?)
end
```

```output
true
true
```

## Optional.to_result

```text
Optional.to_result(o: Optional[T], message: String) -> Result[T]
```

Gives `ok(value)`, or `error(message)` for `none`, so `try` can pass the error on.

```agentica
def first_even(numbers: List[Int]) -> Optional[Int]
  for n in numbers
    if n % 2 == 0
      return some(n)
    end
  end
  return none
end

def half(numbers: List[Int]) -> Result[Int]
  n = try first_even(numbers).to_result("no even number")
  return ok(n / 2)
end

def main() -> Void
  puts(half([3, 8]))
  puts(half([3, 5]))
end
```

```output
ok(4)
error("no even number")
```

## Optional or Result

Use an Optional when having no value is normal and needs no reason: a lookup that finds nothing, a setting the caller left out. Use a [Result](/tour/results-and-try/) when something failed and the caller needs to know why, such as a parse or a file read. `to_result("message")` turns the first into the second when a missing value is an error for the caller. `List.find` and `Lazy.find` give a Result with `error("not found")`, not an Optional.
