---
title: Control flow
weight: 5
description: if, while, for, break, next, boolean operators and case on values.
---

## if, elsif, else

The condition must be a `Bool`.

```agentica
def main() -> Void
  temperature = 18
  if temperature > 25
    puts("hot")
  elsif temperature > 15
    puts("mild")
  else
    puts("cold")
  end
end
```

```output
mild
```

## Boolean operators

`and`, `or` and `not` (or `&&`, `||`, `!`) combine `Bool` values. `and` and `or` stop early when the left side decides the answer.

```agentica
def main() -> Void
  sunny = true
  warm = false
  puts(sunny and warm)
  puts(sunny || warm)
  puts(not warm)
  puts(!(sunny && warm))
end
```

```output
false
true
true
true
```

## while

`while` repeats its block while the condition holds.

```agentica
def main() -> Void
  n = 1
  while n < 50
    n *= 3
  end

  puts(n)
end
```

```output
81
```

## for

`for` walks through a list. The loop variable is read-only. Use `_` to drop it (see [Variables](/tour/variables/)).

```agentica
def main() -> Void
  for fruit in ["apple", "pear", "plum"]
    puts(fruit)
  end

  for _ in 1..2     # the body does not need the number
    puts("tick")
  end
end
```

```output
apple
pear
plum
tick
tick
```

To count, walk through a range: `a..b` includes `b`, `a...b` leaves it out. `n.times` runs a block `n` times. See [Range](/library/data-structures/range/) for more.

```agentica
def main() -> Void
  for i in 1..3
    puts(i)
  end

  2.times do |i|
    puts("round #{i}")
  end
end
```

```output
1
2
3
round 0
round 1
```

## break and next

`break` leaves the loop. `next` skips to the next round.

```agentica
def main() -> Void
  for n in [1, 2, 3, 4, 5, 6]
    if n % 2 == 0
      next
    end

    if n > 4
      break
    end

    puts(n)
  end
end
```

```output
1
3
```

## case on values

`case` runs the first arm that matches; `_` matches anything. On a number, string or `Bool`, end with a `_` arm.

```agentica
def describe(n: Int) -> String
  case n
    0 -> return "zero"
    1 -> return "one"
    _ -> return "many"
  end
end

def main() -> Void
  puts(describe(0))
  puts(describe(1))
  puts(describe(7))
end
```

```output
zero
one
many
```

An arm can hold more lines:

```agentica
def main() -> Void
  command = "add"
  total = 10
  case command
    "add" ->
      total += 5
      puts("added")
    "reset" -> total = 0
    _ -> puts("unknown command")
  end

  puts(total)
end
```

```output
added
15
```

`case` is most useful with enums: see [Enums and case](/tour/enums-and-case/).

## Statements, not expressions

`if` and `case` give no value. Return from them or assign inside them:

```agentica
def sign(n: Int) -> String
  if n < 0
    return "negative"
  end

  return "not negative"
end

def main() -> Void
  puts(sign(-3))
end
```

```output
negative
```
