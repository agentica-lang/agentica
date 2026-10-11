---
title: Result and try
weight: 12
description: Return errors as values with Result, check them, and pass them on with try.
---

## Result

A function that can fail returns `Result[T]`. It is either `ok(value)` or
`error(message)`. The message is always a `String`.

```agentica
def divide(a: Int, b: Int) -> Result[Int]
  if b == 0
    return error("division by zero")
  end
  return ok(a / b)
end

def main() -> Void
  puts(divide(10, 2))
  puts(divide(1, 0))
end
```

```output
ok(5)
error("division by zero")
```

## Look inside a Result

```agentica
def main() -> Void
  good = "12".to_i
  bad = "x".to_i
  puts(good.ok?)
  puts(bad.ok?)
  puts(good.unwrap!)
  puts(bad.unwrap_or(0))
  puts(bad.message)
end
```

```output
true
false
12
0
cannot convert "x" to Int
```

`unwrap!` stops the program when the Result is an error:

```agentica {expect="RUNTIME-UNWRAP-ERROR"}
def main() -> Void
  n = "x".to_i.unwrap!
end
```

## case on a Result

`ok(...)` and `error(...)` also work as patterns:

```agentica
def main() -> Void
  case "42".to_i
    ok(n) -> puts("number #{n}")
    error(message) -> puts("bad: #{message}")
  end
end
```

```output
number 42
```

## try

`try` takes the value out of an `ok`. On an `error`, it returns that error from
the current function at once. The function must return a `Result`.

```agentica
def add_texts(a: String, b: String) -> Result[Int]
  x = try a.to_i
  y = try b.to_i
  return ok(x + y)
end

def main() -> Void
  puts(add_texts("2", "3"))
  puts(add_texts("2", "three"))
end
```

```output
ok(5)
error("cannot convert \"three\" to Int")
```

## Results with no value

`Result[Void]` means "worked, or failed with a message". Return `ok()` on
success.

```agentica
def check_age(age: Int) -> Result[Void]
  if age < 0
    return error("age must not be negative")
  end
  return ok()
end

def main() -> Void
  puts(check_age(30))
  puts(check_age(-1))
end
```

```output
ok()
error("age must not be negative")
```

## Error needs a type

`error("...")` alone does not say which `Result` it is. Give it a type, for
example with an annotation:

```agentica
def main() -> Void
  r: Result[Int] = error("not ready")
  puts(r.unwrap_or(-1))
end
```

```output
-1
```

Without the annotation, `r = error("not ready")` is the error
`CHECK-RESULT-TYPE`.

## ! means it can halt

By convention, a name ending in `!` stops the program on failure, and a name
ending in `?` returns a `Bool`. `to_i` returns a Result; `to_i!` returns the
number or halts.
