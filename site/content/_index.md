---
title: Agentica
description: Agentica is Ruby with static types. Ruby-like syntax, checked before running, with immutable values.
---

Agentica is Ruby with static types. It has Ruby-like syntax. Every program is
checked before it runs, and values never change in place. The language is small
on purpose, so people and AI agents can write, read and fix programs with few
surprises. Every error has a stable code, a source position and often a hint
with the fix.

```agentica
struct Item
  name: String
  price: Int
end

enum Size
  Small
  Large(Int)
end

def size_of(item: Item) -> Size
  if item.price > 4
    return Size.Large(item.price)
  end
  return Size.Small
end

def parse_price(text: String) -> Result[Int]
  price = try text.to_i
  if price < 0
    return error("negative price: #{price}")
  end
  return ok(price)
end

def main() -> Void
  items = [Item(name: "tea", price: 3), Item(name: "cake", price: 5)]
  total = 0
  for item in items
    total += item.price
    case size_of(item)
      Size.Small -> puts("#{item.name} is cheap")
      Size.Large(price) -> puts("#{item.name} costs #{price}")
    end
  end
  puts("total: #{total}")
  puts(parse_price("-2"))
end
```

Run it with `agentica shop.agc`:

```output
tea is cheap
cake costs 5
total: 8
error("negative price: -2")
```

## Read next

- [Getting started](/getting-started/): install Agentica, run a program and
  read its errors.
- [Language tour](/tour/): the language in short pages, one idea at a time.
- [Library](/library/): every builtin module, with one example per function.
- [Language specification](/reference/): the formal grammar and rules.
- [The Aurora VM](/vm/): how your program runs, and the libraries underneath.
