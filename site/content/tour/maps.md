---
title: Maps
weight: 9
description: Map literals, reading keys, adding and removing entries.
---

## Make a map

A map links keys to values. Keys are `Int` or `String`. All keys have one type,
and all values have one type: `Map[K, V]`. A map keeps the order in which keys
were added.

```agentica
def main() -> Void
  stock = {"apple": 3, "pear": 0}
  puts(stock)
  puts(stock.size)
end
```

```output
{"apple": 3, "pear": 0}
2
```

An empty map needs a known type:

```agentica
def main() -> Void
  ages: Map[String, Int] = {}
  ages = ages.put("Ana", 25)
  puts(ages)
end
```

```output
{"Ana": 25}
```

## Read a key

`map[key]` gives the value. A missing key stops the program.

```agentica
def main() -> Void
  stock = {"apple": 3}
  puts(stock["apple"])
end
```

```output
3
```

`get` with a default never fails. `get` without one gives a
[Result](/tour/results-and-try/).

```agentica
def main() -> Void
  stock = {"apple": 3}
  puts(stock.get("kiwi", 0))
  puts(stock.get("apple"))
  puts(stock.get("kiwi").ok?)
  puts(stock.has_key?("apple"))
end
```

```output
0
ok(3)
false
true
```

## Add, change and remove

`put` gives a new map with the entry added or replaced. `delete` gives a new
map without the key. The old map does not change.

```agentica
def main() -> Void
  stock = {"apple": 3}
  more = stock.put("pear", 5)
  more = more.put("apple", 4)
  less = more.delete("pear")
  puts(stock)
  puts(more)
  puts(less)
end
```

```output
{"apple": 3}
{"apple": 4, "pear": 5}
{"apple": 4}
```

## Walk a map

`keys` and `values` give lists in insertion order.

```agentica
def main() -> Void
  prices = {"tea": 3, "cake": 5}
  for name in prices.keys
    puts("#{name}: #{prices[name]}")
  end
  puts(prices.values)
end
```

```output
tea: 3
cake: 5
[3, 5]
```

## Count things

```agentica
def main() -> Void
  counts: Map[String, Int] = {}
  for word in "a b a c a".split(" ")
    counts = counts.put(word, counts.get(word, 0) + 1)
  end
  puts(counts)
end
```

```output
{"a": 3, "b": 1, "c": 1}
```

For records with fixed fields of different types, use a
[struct](/tour/structs/) instead. See the [Map library page](/library/map/)
for every function.
