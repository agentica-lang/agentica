---
title: ATS
weight: 3
description: Share a counter or a cache between tasks in one mutable table.
---

An `ATS[K, V]` (Agentica Table Storage) is a table that tasks share and update in place, like Erlang's ETS. Values stay immutable; a table is the one shared place that changes. Use a [Channel](/library/concurrency/channel/) to pass messages, and a table for state that many tasks read and update, such as a counter or a cache.

- A table is a handle: passing it to a function or task shares it, it is never copied. A constant cannot hold one (`CHECK-CONSTANT-TYPE`). `ATS` is a reserved name.
- Keys are `Int` or `String`, else `CHECK-MAP-KEY-TYPE`. Values are data with no `Fn`, `Task`, `Channel`, handle or table inside, and not `Nil`, else `CHECK-ATS-VALUE`.
- Each call is atomic, on any scheduler. No call takes a block, so a call never waits for user code.
- All but `new` also work as methods: `hits.add("home", 1)` is `ATS.add(hits, "home", 1)`.
- A table has no `==`, no text and no JSON encoding; `IO.inspect` prints `<ATS>`. Use `to_map` to see the contents.
- The garbage collector frees a table when nothing refers to it. No task owns it, and there is no size limit or expiry.

## ATS.new

```text
ATS.new() -> ATS[K, V]
```

Creates an empty table. It needs an expected type (annotation, parameter, field or return type), else `CHECK-EXPECTED-TYPE`.

```agentica {expect="CHECK-EXPECTED-TYPE"}
def main() -> Void
  hits = ATS.new()
end
```

```agentica {expect="CHECK-ATS-VALUE"}
def main() -> Void
  jobs: ATS[String, Task[Int]] = ATS.new()
end
```

## ATS.put, ATS.put_new and ATS.get

```text
ATS.put(table: ATS[K, V], key: K, value: V) -> Void
ATS.put_new(table: ATS[K, V], key: K, value: V) -> Bool
ATS.get(table: ATS[K, V], key: K) -> Result[V]
ATS.has_key?(table: ATS[K, V], key: K) -> Bool
```

`put` inserts or replaces. `put_new` inserts only when the key is absent and gives `true`; `false` leaves the table unchanged. `get` gives `ok(value)`, or an error when the key is absent.

```agentica
def main() -> Void
  names: ATS[Int, String] = ATS.new()
  names.put(1, "ana")
  names.put(1, "eve")
  puts(names.put_new(1, "bob"))
  puts(names.put_new(2, "bob"))
  puts(names.get(1).unwrap!)
  puts(names.get(3).ok?)
  puts(names.has_key?(2))
end
```

```output
false
true
eve
false
true
```

## ATS.add

```text
ATS.add(table: ATS[K, Int], key: K, n: Int) -> Int
```

Adds `n` to the value of the key, an absent key counting as 0, and gives the new value. The read and the write are one atomic step, so tasks that add at the same time lose no update. It works only on a table of `Int` values, else `CHECK-TYPE-MISMATCH`. A result outside the 64-bit range stops with `RUNTIME-INTEGER-OVERFLOW` and leaves the table unchanged.

```agentica
def count_visits(hits: ATS[String, Int]) -> Void
  for _ in 1..100
    hits.add("home", 1)
  end
end

def main() -> Void
  hits: ATS[String, Int] = ATS.new()
  tasks = [1, 2, 3, 4].map do |_| Task.spawn(&count_visits, hits) end
  tasks.each do |task| Task.await(task) end
  puts(hits.get("home").unwrap!)
end
```

```output
400
```

## ATS.delete

```text
ATS.delete(table: ATS[K, V], key: K) -> Void
```

Removes the key; an absent key is ignored.

## ATS.size, ATS.keys and ATS.to_map

```text
ATS.size(table: ATS[K, V]) -> Int
ATS.keys(table: ATS[K, V]) -> List[K]
ATS.to_map(table: ATS[K, V]) -> Map[K, V]
```

Each reads the table as it is at the call. `keys` and `to_map` list the keys in first-insertion order; a key deleted and put again goes to the end, as in `Map`. There is no `values` and no `get` with a default: use `to_map` and `Result.unwrap_or`.

```agentica
def main() -> Void
  stock: ATS[String, Int] = ATS.new()
  stock.put("tea", 3)
  stock.put("milk", 1)
  stock.put("bread", 2)
  stock.delete("tea")
  stock.put("tea", 5)
  puts(stock.size)
  puts(stock.keys)
  IO.inspect(stock.to_map)
end
```

```output
3
["milk", "bread", "tea"]
{"milk": 1, "bread": 2, "tea": 5}
```

## A cache that tasks fill

The first task that misses a key computes its value and stores it with `put_new`; a task that misses at the same time computes it too, but only one value is stored. A second table counts the work.

```agentica
struct Shared
  cache: ATS[Int, String]
  stats: ATS[String, Int]
end

def lookup(shared: Shared, n: Int) -> String
  found = shared.cache.get(n)
  if found.ok?
    return found.unwrap!
  end

  text = "#{n} squared is #{n * n}"
  if shared.cache.put_new(n, text)
    shared.stats.add("stored", 1)
  end

  return text
end

def work(shared: Shared) -> Void
  for n in 1..3
    lookup(shared, n)
  end
end

def main() -> Void
  cache: ATS[Int, String] = ATS.new()
  stats: ATS[String, Int] = ATS.new()
  shared = Shared(cache: cache, stats: stats)
  tasks = [1, 2, 3].map do |_| Task.spawn(&work, shared) end
  tasks.each do |task| Task.await(task) end
  puts(stats.get("stored").unwrap!)
  cache.keys.sort.each do |n|
    puts(cache.get(n).unwrap!)
  end
end
```

```output
3
1 squared is 1
2 squared is 4
3 squared is 9
```

`add` is the one atomic update and `put_new` the one conditional insert. There are no transactions over several keys: to update other values safely, let one owner task do the writes ([State owned by one task](/library/concurrency/channel/#state-owned-by-one-task)).
