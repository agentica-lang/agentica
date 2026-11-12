---
title: Blocks
weight: 7
description: Blocks with do ... end, closures and passing blocks to your own functions.
---

## A block

A block is a small function written right after a call, between `do` and `end`. Its parameters go between bars.

```agentica
def main() -> Void
  doubled = [1, 2, 3].map do |x| x * 2 end

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

## Braces

A call without arguments can take its block in braces instead, on one line or several. A call with arguments takes `do ... end`. Nothing chains after the `end` of a `do` block (`CHECK-CHAIN-AFTER-END`): to call a method on the result, write the block in braces, `xs.map { |x| x * x }.sum`, or give the result a name first.

```agentica
def main() -> Void
  squares = [1, 2, 3].map { |x| x * x }
  puts(squares)
end
```

```output
[1, 4, 9]
```

## Blocks that return nothing

`each` runs the block for every element.

```agentica
def main() -> Void
  ["tea", "cake"].each do |item| puts("I like #{item}") end
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
  [1, 2].each do |x| total += x end
end
```

## return in a block

`return` inside a block leaves only the block, with that value:

```agentica
def main() -> Void
  labels = [5, 50].map do |n|
    return "big" if n > 10

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
def twice(value: Int, f: Fn[Int, Int]) -> Int = f.call(f.call(value))

def main() -> Void
  result = twice(3) do |n| n + 10 end
  puts(result)
end
```

```output
23
```

A call with no other argument drops the empty `()` before its block, also for your own function. Without a block, keep the `()`: a bare name is never a call.

```agentica
def answer(f: Fn[Int]) -> Int = f.call()

def main() -> Void
  puts(answer do 42 end)
  puts(answer { 7 })
end
```

```output
42
7
```

## Lambdas

A block always follows a call. A function value of its own, to keep in a variable, a field or a list, is a lambda: `->(x) { ... }`, with the body in braces over one line or several. Its parameter types come from the `Fn` type it is given, from annotations, or from their uses in the body: in `->(x) { x + 1 }` the `+ 1` makes `x` an `Int`. When the uses leave no single type, as `x * 2` (an `Int`, or a `String` to repeat), annotate: `->(x: Int) { x * 2 }` (`CHECK-BLOCK-TYPE` otherwise). A lambda without parameters drops the parentheses: `-> { 42 }`.

```agentica
def main() -> Void
  step = 2
  add_step: Fn[Int, Int] = ->(n) { n + step }
  answer = -> { 40 }
  puts(add_step.call(answer.call()))
  puts([1, 2].map(add_step))
end
```

```output
42
[3, 4]
```

Where a call takes a block, the block is the one way to write it: `xs.map(->(x: Int) { x + 1 })` is an error whose help shows `xs.map do |x| ... end`.

## Chains over several lines

A line that starts with a dot and a name continues the line before it, so a long chain of method calls and blocks in braces reads one step per line, with no parentheses. A comment may end a line, or sit alone on a line between two steps. A blank line ends the statement.

```agentica
def main() -> Void
  scores = [3, 8, 5, 10, 1]
    .select { |x| x > 2 } # drop the small ones
    # then double what is left
    .map { |x| x * 2 }
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
