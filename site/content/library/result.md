---
title: Result
weight: 5
description: Build and read Result values.
---

`Result[T]` is `ok(value)` or `error(message)`. The tour page
[Result and try](/tour/results-and-try/) explains how to use it. The functions
below are also methods: `Result.ok?(r)` is `r.ok?`.

## ok

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
```

```agentica
def main() -> Void
  puts(ok(3))
  puts(ok("yes"))
end
```

```output
ok(3)
ok("yes")
```

## error

```text
error(message: String) -> Result[T]
```

The checker must know which `Result` type it is: from an annotation, a return
type, a parameter or a field.

```agentica
def fail_now() -> Result[Int]
  return error("broken")
end

def main() -> Void
  puts(fail_now())
end
```

```output
error("broken")
```

## Result.ok?

```text
Result.ok?(r: Result[T]) -> Bool
```

```agentica
def main() -> Void
  puts("1".to_i.ok?)
  puts("one".to_i.ok?)
end
```

```output
true
false
```

## Result.unwrap!

```text
Result.unwrap!(r: Result[T]) -> T
```

Gives the value, or stops the program with `RUNTIME-UNWRAP-ERROR`.

```agentica
def main() -> Void
  puts("5".to_i.unwrap! * 2)
end
```

```output
10
```

## Result.unwrap_or

```text
Result.unwrap_or(r: Result[T], default: T) -> T
```

Gives the value, or the default for an error. The default is always computed.

```agentica
def main() -> Void
  puts("5".to_i.unwrap_or(0))
  puts("five".to_i.unwrap_or(0))
end
```

```output
5
0
```

## Result.message

```text
Result.message(r: Result[T]) -> String
```

Gives the error message, or `""` for a success.

```agentica
def main() -> Void
  puts("five".to_i.message)
  puts("[" + "5".to_i.message + "]")
end
```

```output
cannot convert "five" to Int
[]
```
