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

A `case` needs both arms, `some(n) ->` and `none ->`, or a final `_`. `==` compares two Optionals whose items have `==`: `age == none`, `age == some(31)`. An Optional prints as `some(31)` or `none`. A field or parameter may default to `none`: `port: Optional[Int] = none`. In [JSON](/library/text-and-data/json/#optional-values), `none` is `null` and `some(x)` is `x`.

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
