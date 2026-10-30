---
title: Variables
weight: 2
description: Create and update variables, type annotations and scope.
---

## Create a variable

The first assignment creates a variable. Its type comes from the value.

```agentica
def main() -> Void
  name = "Ana"
  age = 25
  puts("#{name} is #{age}")
end
```

```output
Ana is 25
```

## Update a variable

A later assignment changes the value, not the type. `+=`, `-=`, `*=`, `/=` and `%=` are short forms, and the variable must already exist.

```agentica
def main() -> Void
  count = 1
  count = count + 1
  count += 10
  puts(count)
end
```

```output
12
```

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1
  count = "one"      # error: count is an Int
end
```

## Type annotations

Write the type when the value does not show it, such as an empty list.

```agentica
def main() -> Void
  total: Float = 0.5
  names: List[String] = []
  names = names.push("Ana")
  puts(total)
  puts(names)
end
```

```output
0.5
["Ana"]
```

## Discard with _

`_` is a discard wherever a name is bound: an assignment, a `for` variable, a block or function parameter, or a pattern slot. It binds nothing, can repeat and never conflicts. Reading it is `CHECK-UNKNOWN-NAME`.

```agentica
def load(n: Int) -> Int
  puts("load #{n}")
  return n
end

def main() -> Void
  _ = load(1)          # keep the call, drop its value
  for _ in 1..2        # the body does not need the number
    puts("tick")
  end

  {"a": 1, "b": 2}.each do |_, v|   # drop the key
    puts(v)
  end

  case Result.Ok(3)
    ok(_) -> puts("fine")           # drop the payload
    error(_) -> puts("failed")
  end
end
```

```output
load 1
tick
tick
1
2
fine
```

```agentica {expect="CHECK-UNKNOWN-NAME"}
def main() -> Void
  _ = 1
  puts(_)            # error: _ cannot be read
end
```

`_: Int = x` is `PARSE-UNEXPECTED-TOKEN`, `_ = puts("x")` is `CHECK-VOID-VALUE` and `_ += 1` is `CHECK-UNKNOWN-NAME`.

## Scope

A variable made inside a block (`if`, `while`, `for`, ...) is gone after its `end`. Create it before the block to use it after.

```agentica
def main() -> Void
  message = "small"
  n = 12
  if n > 10
    message = "big"
  end

  puts(message)
end
```

```output
big
```

There is no shadowing: a new variable cannot reuse a visible name.

```agentica {expect="CHECK-SHADOWED-NAME"}
def main() -> Void
  x = 1
  for x in [1, 2]     # error: x is already visible
    puts(x)
  end
end
```

## Names

Variable, function and field names start with a lowercase letter or `_`. Type names start with an uppercase letter. `a = b = 1` is not allowed.
