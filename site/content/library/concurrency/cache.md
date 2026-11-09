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
- `clock: Optional[Fn[Int]] = none`: the time in milliseconds, which only has to go forward. It times the entries and the lease of a drop (below), so a clock that stops also keeps a stalled drop from being taken over. The default is the monotonic clock; a test gives a fake one.

An entry is too big when its key, its value and the 64 bytes of overhead come to more than half of `max_bytes` (see [Eviction](#eviction)): `fetch` and `put_new` do not store it, and `put` does not store it either and removes the older value of its key.

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

`get` gives `some(value)` or `none`; an expired entry is a miss. `put` stores a value and replaces one already there; it is a removal followed by a store, not one atomic step, so a reader may see a miss in between, and a `put` that finds no room or loses the key to another `put` is dropped after the old value is gone. `put_new` stores only when the key has no live value and gives `true` when it stored. `delete` ignores an absent key. `clear` removes every entry; a `put` that runs at the same moment may survive it, or be dropped (the old value of its key is gone either way).

A delete or a clear is not ordered against a `fetch` or `put` of the same key that is in flight: a block that started before the delete may store its value after it. A `get` that starts after a delete has returned does not see the value, unless a `put` of that key that began earlier was stopped for a whole rotation and lands after it (see [Eviction](#eviction)).

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

The bytes the entries take, counted as `max_bytes` is, never above `max_bytes`. When no call is running the count is exact: it is the sum of the entries that are in the cache, and delete, replace, expiry and `cleanup` give their bytes back.

## Expiry

With `ttl_ms`, an entry is never read more than that long after it was written, and a read does not make it live longer (put the version in the key instead: `"msg:#{id}:#{updated_at}"`). Three things remove it:

- `get` and `put_new` treat an expired entry as absent and remove it.
- A generation that has been the young one for half the time to live turns when the next write comes, and the generation before the old one is dropped whole (see [Eviction](#eviction)). Rotation runs only on writes: with no `put` or `fetch` miss, expired entries stay until they are read or `Cache.cleanup` runs. With writes going on, an entry is gone from memory at most about 1.5 times the time to live after it was written, and it can go earlier than the time to live, no sooner than about half of it, as a cache may drop an entry.
- `Cache.cleanup` removes every expired entry at once.

```signature
Cache.cleanup(cache: Cache.Store) -> Int
```

`cleanup` removes every entry past its time to live and gives how many it removed. It is safe from any task at any time, next to `get` and `put`, and keeps the byte count exact. Without `ttl_ms` it removes nothing. To sweep every few seconds, run it in a task of its own:

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

`Cache.memory` keeps three `ATS` tables, called generations. New entries go to the young generation. When an entry does not fit in it, the young generation becomes the old one, the generation before it is dropped whole, and an empty one starts. `get` looks in the young generation and then in the old one, and stores nothing: only `put` and `fetch` do (it only removes an expired entry). An entry therefore leaves one to two rotations after it was written, however often it is read, and a popular key is recomputed by the next `fetch` once about every two rotations. It is a cheap approximation of first in, first out by generation, with no write on a read, which is what keeps `get` fast and free of races with `delete`.

Each live generation holds at most half of `max_bytes` and of `max_entries` (at least one entry), so the cache holds between half and all of them; the size of an entry (key, value and the 64 bytes) is compared with `max_bytes / 2`. On a skewed workload (20,000 keys of 1 KB, the popular ones asked far more often, a budget of 10% of the keys) it kept 63% of the requests as hits (37% at a flatter skew). A simulation of the same requests with the whole budget gives 69% and 45% for exact LRU, and 60% and 34% for emptying the whole cache when it is full.

Dropping a generation deletes its entries one by one (the table of `ATS` has no `clear`), which takes about 5 µs an entry: the one task whose put starts it waits, for example 150 ms for 30,000 entries, and the other tasks go on. A put that finds a drop under way in another task, and no room, is dropped: a cache may forget an entry.

## The byte count is exact

Every entry has an id and its size is recorded under that id. A task that removes an entry (`delete`, a replacing `put`, an expired read, `cleanup`) first adds minus its size to the id with `ATS.add`; only the task whose add makes 0 gives the bytes back, so two tasks that remove the same entry cannot subtract twice and none is lost. A task reserves the size of a new entry with `ATS.add` before it stores it and takes back its own reservation when the entry is not stored. The byte count of a generation goes away with the generation.

A task that was stopped for two drops and then writes to a table that has been reused takes its own entry out again when it wakes. Until then, the entry is readable in that table and uncounted, and if the task is cancelled in between, it stays until that table is dropped: that stale window is a stall that spans a rotation, not a single read. A rotation that stalls for longer than the lease is the same case: another task takes it over. Until the stalled one sees that at its next beat, it removes only entries of dropped generations, never those of the generation the new owner started, and if it still publishes, the cache skips a generation instead of going back to an older one. A skip drops the old generation early, and the table it skipped keeps its dropped entries, uncounted and unread, until a later drop empties it. A task cancelled between reserving the bytes of an entry and storing it leaves its reservation counted until that generation is dropped. A drop beats its heart as it empties the table; one whose task did not beat for two seconds on the cache's clock (it was cancelled) is taken over by one other task, chosen with `ATS.add`, and only the current generation can be dropped.

## Writing another cache

An implementation returns a `Cache.Store` whose functions follow this contract, each safe to call from any task at any time:

- `get` gives the value, or `none`; an expired entry is a miss.
- `put` stores a value and replaces one already there; a value too big for the cache is not stored and the old value of its key goes.
- `put_new` stores only when the key has no live value, and gives `true` when it stored.
- `delete` ignores an absent key, and `clear` removes every entry.
- `cleanup` removes every expired entry and gives how many; it gives 0 when the cache has no time to live.
- `bytes` gives the bytes of the entries, counted as the implementation counts `max_bytes`.

A block is a value only when it is passed to a call, so a helper that takes a block and returns it (`def block1[A, R](f: Fn[A, R]) -> Fn[A, R]`) is how a function value holds the state of the cache. This one keeps everything in a table, with no limit, and counts entries where a cache with a byte limit counts bytes:

```agentica
import Cache from "std/cache"

def block0[R](f: Fn[R]) -> Fn[R]
  return f
end

def block1[A, R](f: Fn[A, R]) -> Fn[A, R]
  return f
end

def block2[A, B, R](f: Fn[A, B, R]) -> Fn[A, B, R]
  return f
end

def table_get(table: ATS[String, String], key: String) -> Optional[String]
  found = table.get(key)
  if found.ok?
    return some(found.unwrap!)
  end

  return none
end

def table_clear(table: ATS[String, String]) -> Void
  for key in table.keys
    table.delete(key)
  end
end

def table_cache() -> Cache.Store
  table: ATS[String, String] = ATS.new()
  return Cache.Store(
    get: block1() do |key| table_get(table, key) end,
    put: block2() do |key, value| table.put(key, value) end,
    put_new: block2() do |key, value| table.put_new(key, value) end,
    delete: block1() do |key| table.delete(key) end,
    clear: block0() do table_clear(table) end,
    cleanup: block0() do 0 end,
    bytes: block0() do table.size end,
  )
end

def main() -> Void
  cache = table_cache()
  puts(Cache.fetch(cache, "a") do "one" end)
  puts(Cache.fetch(cache, "a") do "two" end)
  puts(Cache.put_new(cache, "a", "three"))
end
```

```output
one
one
false
```
