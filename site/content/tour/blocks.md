---
title: Blocks
weight: 7
description: Blocks with do ... end, closures and passing blocks to your own functions.
---

## A block

A block is a small function written right after a call, between `do` and `end`. Its parameters go between bars.

```agentica
def main() -> Void
  doubled = [1, 2, 3].map do |x|
    x * 2
  end
  puts(doubled)
end
```

```output
[2, 4, 6]
```

The last expression is the block's value. A short block fits on one line:

```agentica
def main() -> Void
  evens = [1, 2, 3, 4].select do |x| x % 2 == 0 end
  puts(evens)
end
```

```output
[2, 4]
```

## Blocks that return nothing

`each` runs the block for every element.

```agentica
def main() -> Void
  ["tea", "cake"].each do |item|
    puts("I like #{item}")
  end
end
```

```output
I like tea
I like cake
```

## Two parameters

`reduce` passes the running value and the next element.

```agentica
def main() -> Void
  total = [1, 2, 3, 4].reduce(0) do |sum, x| sum + x end
  puts(total)
end
```

```output
10
```

## Closures

A block can read the variables around it. It sees their values at the moment the block is made.

```agentica
def main() -> Void
  rate = 3
  scaled = [1, 2].map do |x| x * rate end
  puts(scaled)
end
```

```output
[3, 6]
```

A block cannot assign to an outer variable. Build the value with `map` or `reduce`, or use a `for` loop:

```agentica {expect="CHECK-CAPTURED-ASSIGNMENT"}
def main() -> Void
  total = 0
  [1, 2].each do |x|
    total += x
  end
end
```

## return in a block

`return` inside a block leaves only the block, with that value:

```agentica
def main() -> Void
  labels = [5, 50].map do |n|
    if n > 10
      return "big"
    end
    "small"
  end
  puts(labels)
end
```

```output
["small", "big"]
```

## Pass a block to your own function

The last parameter of your function must be a `Fn`. The block becomes that argument.

```agentica
def twice(value: Int, f: Fn[Int, Int]) -> Int
  return f.call(f.call(value))
end

def main() -> Void
  result = twice(3) do |n| n + 10 end
  puts(result)
end
```

```output
23
```

## Keep a block

A block always follows a call; there are no standalone lambdas. To keep a block in a variable, pass it to a function that returns it:

```agentica
def keep(f: Fn[Int, Int]) -> Fn[Int, Int]
  return f
end

def main() -> Void
  add_one = keep() do |n| n + 1 end
  puts(add_one.call(1))
  puts([1, 2].map(add_one))
end
```

```output
2
[2, 3]
```

## Chains over several lines

A line that starts with a dot and a name continues the line before it, so a long chain of method calls and blocks reads one step per line, with no parentheses. A comment may end a line, or sit alone on a line between two steps. A blank line ends the statement.

```agentica
def main() -> Void
  scores = [3, 8, 5, 10, 1]
    .select do |x| x > 2 end   # drop the small ones
    # then double what is left
    .map do |x|
      x * 2
    end
    .take(3)
  puts(scores)
end
```

```output
[6, 16, 10]
```

A line that starts with `..`, `...` or `|>` does not continue: put a pipe chain in parentheses.

## Annotate when needed

Parameter types come from the call. When the call cannot tell, write the type after the name:

```agentica
def main() -> Void
  doubled = List.map([]) do |x: Int| x * 2 end
  puts(doubled.size)
end
```

```output
0
```

Write blocks with `do ... end`. Ruby's `{ |x| ... }` form does not exist.
