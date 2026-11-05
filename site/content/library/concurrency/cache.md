---
title: Cache (std)
weight: 4
description: The std/cache module, a bounded cache of strings that tasks share, built on ATS.
---

`std/cache` is written in Agentica, on top of [ATS](/library/concurrency/ats/): `import Cache from "std/cache"`. A `Cache.Store` keeps computed text, such as a rendered HTML fragment, across requests and never holds more than the byte budget you give it.

- A store is a handle, like an `ATS` table: passing it to a function or task shares it. Every call is safe from any number of tasks on any scheduler, and no block runs inside an `ATS` call.
- Keys and values are `String`. Use `id.to_s` for an `Int` key. There is no `Bytes` value and no expiry by time: put the version in the key (`"msg:#{id}:#{updated_at}"`) and an update makes a new key, so the old entry is never read again and leaves when it is the oldest.
- The budget counts each entry as its key, its value and 64 bytes of overhead.
- There are no methods: call `Cache.get(cache, key)`.

## Cache.new

```signature
Cache.new(max_bytes: Int) -> Cache.Store
```

An empty store. A value that would take more than half of `max_bytes` with its key is never stored (see [Eviction](#eviction)).

## Cache.fetch

```signature
Cache.fetch(cache: Cache.Store, key: String, compute: Fn[String]) -> String
```

Gives the value of `key`. On a miss it runs the block, stores the result and gives it. The block runs outside the store, so it may be slow or call the store. Two tasks that miss the same key at the same moment both run the block, and one result is kept; a block that must run once belongs to one owner task.

```agentica
import Cache from "std/cache"

def render(id: Int, renders: ATS[String, Int]) -> String
  renders.add("renders", 1)
  return "<p>message #{id}</p>"
end

def main() -> Void
  cache = Cache.new(1_000_000)
  renders: ATS[String, Int] = ATS.new()
  for id in [1, 2, 1, 1, 2]
    html = Cache.fetch(cache, "msg:#{id}:v1") do render(id, renders) end
    puts(html)
  end

  puts(renders.get("renders").unwrap!)
end
```

```output
<p>message 1</p>
<p>message 2</p>
<p>message 1</p>
<p>message 1</p>
<p>message 2</p>
2
```

## Cache.get, Cache.put, Cache.delete and Cache.clear

```signature
Cache.get(cache: Cache.Store, key: String) -> Optional[String]
Cache.put(cache: Cache.Store, key: String, value: String) -> Void
Cache.delete(cache: Cache.Store, key: String) -> Void
Cache.clear(cache: Cache.Store) -> Void
```

`get` gives `some(value)` or `none`. `put` stores a value and replaces one already there. `delete` ignores an absent key. `clear` removes every entry and makes the count start again; a `put` that runs at the same moment may survive it.

A delete or a clear is not ordered against a `fetch`, `put` or `get` of the same key that is in flight: a block that started before the delete may store its value after it.

```agentica
import Cache from "std/cache"

def main() -> Void
  cache = Cache.new(10_000)
  Cache.put(cache, "a", "one")
  Cache.put(cache, "a", "two")
  puts(Cache.get(cache, "a"))
  Cache.delete(cache, "a")
  puts(Cache.get(cache, "a"))
end
```

```output
some("two")
none
```

## Cache.bytes

```signature
Cache.bytes(cache: Cache.Store) -> Int
```

The bytes counted so far in the live entries. It is an upper bound of what the cache holds, never above `max_bytes`.

## Eviction

The store keeps three `ATS` tables, called generations. New entries go to the young generation. When an entry does not fit in it, the young generation becomes the old one, the generation before it is dropped whole, and an empty one starts. `get` looks in the young generation and then in the old one; a key found in the old one is copied into the young one, so the keys that are read stay and the keys that are not read are dropped after one to two generations. It is the policy of a generational cache, a cheap approximation of least recently used.

Each live generation holds at most half of `max_bytes`, so the cache holds between half and all of it, and an entry over half is returned and not stored. On a skewed workload (20,000 keys of 1 KB, the popular ones asked far more often, a budget of 10% of the keys) it kept 65% of the requests as hits. A simulation of the same requests with the whole budget gives 69% for exact LRU and 60% for emptying the whole cache when it is full.

Dropping a generation deletes its keys one by one, which takes about 2 µs an entry: the one task whose put starts it waits, for example 70 ms for 30,000 entries, and the other tasks go on. A put that finds a drop under way in another task, and no room, is dropped: a cache may forget an entry.

## The byte count does not drift

The count of a generation only grows. A task reserves the size of its entry with `ATS.add` before it stores it, and takes back the same size itself if the entry was not stored, so every add is matched by an entry or by its own subtract. Nothing subtracts the size of a value it read, so two tasks that replace or delete the same key cannot subtract twice. The cost is that `put` over a key, and `delete`, leave their bytes counted until the generation is dropped, so a store that replaces or deletes keys all the time rotates sooner than its content needs.

A task that was stopped for two drops and then writes to a table that has been reused takes its own entry out again. A drop that its task never finishes (the task was cancelled) is taken over by another task after two seconds.
