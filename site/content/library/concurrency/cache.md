---
title: Cache (std)
weight: 4
description: The std/cache module, a small contract for caches of strings that tasks share, and an in-memory implementation of it built on ATS.
---

`std/cache` is written in Agentica, on top of [ATS](/library/concurrency/ats/): `import Cache from "std/cache"`. It keeps computed text, such as a rendered HTML fragment, across requests, within a byte budget and an optional time to live.

- A `Cache.Store` is a struct of function values: the contract that every cache implements, since Agentica has no traits. `Cache.memory` builds one; a package with another eviction strategy builds the same struct, and `get`, `put`, `fetch` and the other helpers of this module work on all of them.
- A store is a handle, like an `ATS` table: passing it to a function or task shares it. Every call is safe from any number of tasks on any scheduler, and no block runs inside an `ATS` call.
- Keys and values are `String`. Use `id.to_s` for an `Int` key. There is no `Bytes` value.
- There are no methods: call `Cache.get(cache, key)`.

## Cache.memory

```signature
Cache.memory(max_bytes: Int, options: Cache.Options = Cache.Options()) -> Cache.Store
```

An empty cache that holds at most `max_bytes`, counting each entry as its key, its value and 64 bytes of overhead. `Cache.Options` has three fields, each with a default:

- `max_entries: Int = 0`: at most this many entries, 0 for no limit.
- `ttl_ms: Int = 0`: the time to live of an entry in milliseconds, 0 for none (see [Expiry](#expiry)).
- `clock: Optional[Fn[Int]] = none`: the time in milliseconds, which only has to go forward. The default is the monotonic clock; a test gives a fake one.

A value that would take more than half of `max_bytes` with its key is never stored (see [Eviction](#eviction)), and `put` of such a value removes the older value of its key.

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
  cache = Cache.memory(1_000_000)
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

## Cache.get, put, put_new, delete and clear

```signature
Cache.get(cache: Cache.Store, key: String) -> Optional[String]
Cache.put(cache: Cache.Store, key: String, value: String) -> Void
Cache.put_new(cache: Cache.Store, key: String, value: String) -> Bool
Cache.delete(cache: Cache.Store, key: String) -> Void
Cache.clear(cache: Cache.Store) -> Void
```

`get` gives `some(value)` or `none`; an expired entry is a miss. `put` stores a value and replaces one already there. `put_new` stores only when the key has no live value and gives `true` when it stored. `delete` ignores an absent key. `clear` removes every entry; a `put` that runs at the same moment may survive it.

A delete or a clear is not ordered against a `fetch`, `put` or `get` of the same key that is in flight: a block that started before the delete may store its value after it.

```agentica
import Cache from "std/cache"

def main() -> Void
  cache = Cache.memory(10_000)
  Cache.put(cache, "a", "one")
  Cache.put(cache, "a", "two")
  puts(Cache.get(cache, "a"))
  puts(Cache.put_new(cache, "a", "three"))
  Cache.delete(cache, "a")
  puts(Cache.get(cache, "a"))
end
```

```output
some("two")
false
none
```

## Cache.bytes

```signature
Cache.bytes(cache: Cache.Store) -> Int
```

The bytes the entries take, counted as `max_bytes` is, never above `max_bytes`. The count is exact: it is the sum of the entries that are in the cache, and delete, replace, expiry and `cleanup` give their bytes back.

## Expiry

With `ttl_ms`, an entry lives that long after it was written, and a read does not make it live longer (put the version in the key instead: `"msg:#{id}:#{updated_at}"`). Three things remove it:

- `get` and `put_new` treat an expired entry as absent and remove it.
- A generation that has been the young one for half the time to live is dropped whole when the next `put` or `fetch` miss comes (see [Eviction](#eviction)), so no entry outlives the time to live by more than a generation or two, even if nobody reads it.
- `Cache.cleanup` removes every expired entry at once.

```signature
Cache.cleanup(cache: Cache.Store) -> Int
```

`cleanup` removes every entry past its time to live and gives how many it removed (a key that was read from the old generation and copied forward is two entries until both expire). It is safe from any task at any time, next to `get` and `put`, and keeps the byte count exact. Without `ttl_ms` it removes nothing. To sweep every few seconds, run it in a task of its own:

```agentica {mode="check"}
import Cache from "std/cache"

def sweep_forever(cache: Cache.Store) -> Void
  while true
    _ = Cache.cleanup(cache)
    Task.sleep(5_000)
  end
end

def main() -> Void
  cache = Cache.memory(64 * 1024 * 1024, Cache.Options(ttl_ms: 60_000))
  _ = Task.spawn(&sweep_forever, cache)
end
```

An example with a short time to live:

```agentica
import Cache from "std/cache"

def main() -> Void
  cache = Cache.memory(10_000, Cache.Options(ttl_ms: 20))
  Cache.put(cache, "a", "one")
  puts(Cache.get(cache, "a"))
  Task.sleep(60)
  puts(Cache.cleanup(cache))
  puts(Cache.bytes(cache))
  puts(Cache.get(cache, "a"))
end
```

```output
some("one")
1
0
none
```

## Eviction

`Cache.memory` keeps three `ATS` tables, called generations. New entries go to the young generation. When an entry does not fit in it, the young generation becomes the old one, the generation before it is dropped whole, and an empty one starts. `get` looks in the young generation and then in the old one; a key found in the old one is copied into the young one, so the keys that are read stay and the keys that are not read are dropped after one to two generations. It is the policy of a generational cache, a cheap approximation of least recently used.

Each live generation holds at most half of `max_bytes` and of `max_entries` (at least one entry), so the cache holds between half and all of them, and an entry over half of `max_bytes` is returned and not stored. On a skewed workload (20,000 keys of 1 KB, the popular ones asked far more often, a budget of 10% of the keys) it kept 65% of the requests as hits. A simulation of the same requests with the whole budget gives 69% for exact LRU and 60% for emptying the whole cache when it is full.

Dropping a generation deletes its entries one by one, which takes about 5 µs an entry: the one task whose put starts it waits, for example 150 ms for 30,000 entries, and the other tasks go on. A put that finds a drop under way in another task, and no room, is dropped: a cache may forget an entry.

## The byte count is exact

Every entry has an id and its size is recorded under that id. A task that removes an entry (`delete`, a replacing `put`, an expired read, `cleanup`) first adds minus its size to the id with `ATS.add`; only the task whose add makes 0 gives the bytes back, so two tasks that remove the same entry cannot subtract twice and none is lost. A task reserves the size of a new entry with `ATS.add` before it stores it and takes back its own reservation when the entry is not stored. The byte count of a generation goes away with the generation.

A task that was stopped for two drops and then writes to a table that has been reused takes its own entry out again. A drop that its task never finishes (the task was cancelled) is taken over by another task after two seconds.

## Writing another cache

An implementation returns a `Cache.Store` whose functions follow the contract of its fields: `get`, `put`, `put_new`, `delete`, `clear`, `cleanup` and `bytes`, each safe from any task. A block is a value only when it is passed to a call, so a helper that takes a block and returns it (`def block1[A, R](f: Fn[A, R]) -> Fn[A, R]`) is how a function value holds the state of the cache.
