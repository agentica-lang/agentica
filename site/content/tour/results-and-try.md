---
title: Result and try
weight: 12
description: Return errors as values with Result, check them, and pass them on with try.
---

## Result

A function that can fail returns `Result[T]`. It is either `ok(value)` or `error(message)`. The error holds an [Error](/library/errors/error/) record, whose `message` is a `String`. A value that may simply be missing, with no error to report, is an [Optional](/library/data-structures/optional/#optional-or-result) instead.

```agentica
def divide(a: Int, b: Int) -> Result[Int]
  return error("division by zero") if b == 0

  ok(a / b)
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
  _n = "x".to_i.unwrap!
end
```

## case on a Result

`ok(...)` and `error(...)` also work as patterns. `error(e)` binds the `Error`: `"#{e}"` and `puts(e)` give its message, and `e.message` is the `String` itself.

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

`try` takes the value out of an `ok`. On an `error`, it returns that error from the current function at once. The function must return a `Result`.

```agentica
def add_texts(a: String, b: String) -> Result[Int]
  x = try a.to_i
  y = try b.to_i
  ok(x + y)
end

def main() -> Void
  puts(add_texts("2", "3"))
  puts(add_texts("2", "three"))
end
```

```output
ok(5)
error("cannot convert \"three\" to Int", kind: "number.parse")
```

## Results with no value

`Result[Void]` means "worked, or failed with a message". Return `ok()` on success.

```agentica
def check_age(age: Int) -> Result[Void]
  return error("age must not be negative") if age < 0

  ok()
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

## A Result must be used

A call whose `Result` is dropped would lose its error, so it is `CHECK-UNUSED-RESULT`. It holds for any call, yours or a builtin, and for `Result[Void]` too.

```agentica {expect="CHECK-UNUSED-RESULT"}
def check_age(age: Int) -> Result[Void]
  return error("age must not be negative") if age < 0

  ok()
end

def main() -> Void
  check_age(-1)
end
```

Handle it with `try`, a `case` or `unwrap!`. To drop it on purpose, write `_ =` in front of the call:

```agentica
def check_age(age: Int) -> Result[Void]
  return error("age must not be negative") if age < 0

  ok()
end

def main() -> Void
  _ = check_age(-1)
  case check_age(30)
    ok(_) -> puts("fine")
    error(message) -> puts(message)
  end
end
```

```output
fine
```

## Error needs a type

`error("...")` alone does not say which `Result` it is. Give it a type, for example with an annotation:

```agentica
def main() -> Void
  r: Result[Int] = error("not ready")
  puts(r.unwrap_or(-1))
end
```

```output
-1
```

Without the annotation, `r = error("not ready")` is the error `CHECK-RESULT-TYPE`.

## ! means it can halt

By convention, a name ending in `!` stops the program on failure; a name ending in `?` returns a `Bool`. `to_i` returns a Result; `to_i!` returns the number or halts.
