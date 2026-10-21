---
title: Map
weight: 2
description: Functions for Map[K, V]. Each one is also a method on maps.
---

Maps are immutable and keep the order in which keys were added. Keys are `Int` or `String`.

## size

```text
Map.size(map: Map[K, V]) -> Int
```

```agentica
def main() -> Void
  puts({"a": 1, "b": 2}.size)
end
```

```output
2
```

`size` is O(1): the map keeps its count.

## get

```text
Map.get(map: Map[K, V], key: K) -> Result[V]
Map.get(map: Map[K, V], key: K, default: V) -> V
```

With two arguments, `get` gives a Result: an error when the key is missing. With a third argument, it gives the value or the default.

```agentica
def main() -> Void
  ages = {"Ana": 25}
  puts(ages.get("Ana"))
  puts(ages.get("Bob").ok?)
  puts(ages.get("Bob", 0))
end
```

```output
ok(25)
false
0
```

`map[key]` also reads a value, and stops the program when the key is missing.

## has_key?

```text
Map.has_key?(map: Map[K, V], key: K) -> Bool
```

```agentica
def main() -> Void
  m = {1: "one"}
  puts(m.has_key?(1))
  puts(m.has_key?(2))
end
```

```output
true
false
```

## put

```text
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]
```

Adds or replaces an entry. A replaced key keeps its place.

```agentica
def main() -> Void
  m = {"a": 1, "b": 2}
  puts(m.put("c", 3))
  puts(m.put("a", 10))
end
```

```output
{"a": 1, "b": 2, "c": 3}
{"a": 10, "b": 2}
```

## delete

```text
Map.delete(map: Map[K, V], key: K) -> Map[K, V]
```

Removes a key. A missing key is fine.

```agentica
def main() -> Void
  m = {"a": 1, "b": 2}
  puts(m.delete("a"))
  puts(m.delete("zzz"))
end
```

```output
{"b": 2}
{"a": 1, "b": 2}
```

## keys and values

```text
Map.keys(map: Map[K, V]) -> List[K]
Map.values(map: Map[K, V]) -> List[V]
```

Both follow insertion order.

```agentica
def main() -> Void
  m = {"x": 1, "y": 2}
  puts(m.keys)
  puts(m.values)
end
```

```output
["x", "y"]
[1, 2]
```

## each

```text
Map.each(map: Map[K, V], f: Fn[K, V, Void]) -> Void
```

Runs the function with each key and value, in insertion order.

```agentica
def main() -> Void
  {"x": 1, "y": 2}.each do |key, value|
    puts("#{key}=#{value}")
  end
end
```

```output
x=1
y=2
```

## filter

```text
Map.filter(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]
```

Keeps the entries for which the function gives `true`, in insertion order. O(n), like `each`.

```agentica
def main() -> Void
  stock = {"apple": 3, "fig": 0, "kiwi": 7}
  puts(stock.filter do |name, count| count > 0 end)
end
```

```output
{"apple": 3, "kiwi": 7}
```
