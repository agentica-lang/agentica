---
title: ATS
weight: 3
description: Share a counter or a cache between tasks in one mutable table.
---

An `ATS[K, V]` (Agentica Table Storage) is a table that tasks share and update in place, like Erlang's ETS. Values stay immutable; a table is the one shared place that changes. Use a [Channel](/library/concurrency/channel/) to pass messages, and a table for state that many tasks read and update, such as a counter or a cache.

- A table is a handle: passing it to a function or task shares it, it is never copied. It may be a struct field, a list element, a `Map` value, or a `Task.spawn` argument or result, but not a value inside a table. A constant cannot hold one (`CHECK-CONSTANT-TYPE`). `ATS` is a reserved name: a user `struct`, `enum` or import alias named `ATS` is `CHECK-REDEFINED-NAME`.
- Keys are `Int` or `String`, else `CHECK-MAP-KEY-TYPE`. Values are data with no `Fn`, `Task`, `Channel`, handle, `Lazy` or table inside, and not `Nil`, else `CHECK-ATS-VALUE` at the value type. The test is deep: it looks through struct fields, list elements, enum payloads, `Map` values and `Result`, and refuses `Fn` because a block can capture a handle. A nested `Result[Void]` is allowed; `V` itself as `Void` is `CHECK-VOID-TYPE`. A type parameter is refused as `V` (a generic enum payload `ATS[String, T]`), since its uses would not be checked; a generic alias is checked where it is used.
- Each call is atomic, on any scheduler: a reader sees the table before or after a write, never half of it. No call takes a block, so no user code runs inside a call, and a call cannot deadlock or re-enter the table.
- All but `new` also work as methods: `hits.add("home", 1)` is `ATS.add(hits, "home", 1)`.
- `puts`, `print`, interpolation and `==` on a table are `CHECK-TYPE-MISMATCH`, `.to_s` is `CHECK-UNKNOWN-METHOD`, and a struct with a table field is `CHECK-NOT-ENCODABLE` as JSON. `IO.inspect` prints `<ATS>` without the contents. Use `to_map` to see them.
- The garbage collector frees a table when nothing refers to it. It is not an OS resource, so the owner rule of handle ownership does not apply: the task that made it does not own it, its end does not close it, and `Task.spawn_owning` is not needed. There is no named global table: a task reaches a table only through a handle it was given. A table belongs to the run that made it, and a call from another run stops with `RUNTIME-ATS-CONTEXT`.
- There is no size limit and no expiry; a bounded or expiring cache belongs in a `std/` module on top of `ATS`. Not supported: ordered tables, duplicate keys, a block-based `update`, a compare-and-swap `replace`, and tables shared between OS processes.
- `put`, `put_new`, `delete` and `add` carry the `concurrency` effect, which also keeps `CHECK-UNUSED-VALUE` away from an ignored `put_new` or `add`.
- `get`, `put`, `put_new`, `has_key?`, `delete` and `add` take O(log n) in the table size, and `size` O(1). `keys` and `to_map` take their snapshot in O(1) without holding back other tasks, and build their list or map in O(n). A write that loses a race to another task builds its change again; each retry is charged to the task's step budget, so a task under heavy contention yields and cannot spin forever.
- In BDD, each scenario runs in its own child VM and runs the step program's `main` again, so a table made in `main` and captured by step blocks is shared by the steps of one scenario and starts fresh in the next. A table cannot go in the JSON state of `BDD.set`.

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
