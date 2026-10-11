---
title: Variables
weight: 2
description: Create and update variables, type annotations and scope.
---

## Create a variable

The first assignment to a name creates a variable. Its type comes from the
value.

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

A later assignment changes the value. The type stays the same.

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

`+=`, `-=`, `*=`, `/=` and `%=` are short forms: `count += 10` means
`count = count + 10`. The variable must already exist.

Giving a variable a value of another type is an error:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1
  count = "one"
end
```

## Type annotations

You can write the type when you create a variable. It is useful for empty
lists and maps, where the value alone does not say the type.

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

## Scope

A variable made inside a block (`if`, `while`, `for`, ...) is gone after that
block's `end`. Create it before the block to use it after.

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

A new variable cannot reuse a name that is already visible: there is no
shadowing.

```agentica {expect="CHECK-SHADOWED-NAME"}
def main() -> Void
  x = 1
  for x in [1, 2]
    puts(x)
  end
end
```

## Names

Variable, function and field names start with a lowercase letter or `_`. Type
names start with an uppercase letter. Assignment is a statement, not an
expression, so `a = b = 1` is not allowed.
