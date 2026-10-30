---
title: Agentica
description: Agentica is Ruby with static types. Ruby-like syntax, checked before running, with immutable values.
---

Agentica is Ruby with static types. It has Ruby-like syntax. Every program is checked before it runs, and values never change in place. The language is small on purpose, so people and AI agents can write, read and fix programs with few surprises. Every error has a stable code, a source position and often a hint with the fix.

The project is hosted on [GitHub](https://github.com/agentica-lang/agentica).

```agentica
# Prices are in cents, so the math stays exact.
TAX_PERCENT = 21

## Returns the price with the tax added.
def with_tax(cents: Int) -> Int
  return cents + cents * TAX_PERCENT / 100
end

def main() -> Void
  prices = [250, 1_000, 99]
  # Ranges include both ends: 1..3 is 1, 2, 3.
  for i in 1..prices.size
    puts("item #{i}: #{with_tax(prices[i - 1])} cents")
  end
  total = prices.map(&with_tax).sum
  puts("total: #{total} cents")
end
```

Run it with `agentica prices.agc`:

```output
item 1: 302 cents
item 2: 1210 cents
item 3: 119 cents
total: 1631 cents
```

## Read next

- [Getting started](/getting-started/): install Agentica, run your first program and check it.
- [Language tour](/tour/): the language in short pages, one idea at a time.
- [Command line](/cli/): every command, option and cache of the `agentica` program.
- [Library](/library/): every builtin module, with one example per function.
- [Language specification](/reference/): the formal grammar and rules.
- [Style guide](/style/): how to write simple code that is easy to read.
- [The Aurora VM](/vm/): how your program runs, and the libraries underneath.
- [Design decisions](/design/): the main design decisions and why each was taken.
