# Cache (`std/cache`)

`import Cache from "std/cache"`. A cache of `String` values that tasks share,
as a contract (`Cache.Store`, a struct of function values: Agentica has no
traits) and `Cache.memory`, an implementation on `ATS`. Written in Agentica.
A store is a handle: passing it shares it. No methods: `Cache.get(cache, key)`.

```text
Cache.memory(max_bytes: Int, options: Cache.Options = Cache.Options()) -> Cache.Store
Cache.Options(max_entries: Int = 0, ttl_ms: Int = 0, clock: Optional[Fn[Int]] = none)
Cache.fetch(cache: Cache.Store, key: String, compute: Fn[String]) -> String
Cache.get(cache: Cache.Store, key: String) -> Optional[String]
Cache.put(cache: Cache.Store, key: String, value: String) -> Void
Cache.put_new(cache: Cache.Store, key: String, value: String) -> Bool
Cache.delete(cache: Cache.Store, key: String) -> Void
Cache.clear(cache: Cache.Store) -> Void
Cache.cleanup(cache: Cache.Store) -> Int
Cache.bytes(cache: Cache.Store) -> Int
```

- `fetch` runs the block on a miss, stores the result and returns it. Tasks
  that miss together may all run the block; one result is kept.
- Keys and values are `String` (`id.to_s` for an `Int` key); no `Bytes`.
  Put the version in the key (`"msg:#{id}:#{updated_at}"`) instead of deleting.
- `Cache.memory`: an entry costs key + value + 64 bytes. Each of two live
  generations holds half of `max_bytes` (and of `max_entries`); the oldest
  generation is dropped whole when the young one is full. `get` stores nothing,
  so an entry leaves 1 to 2 rotations after its write however often it is read.
  An entry whose cost is over `max_bytes / 2` is returned by `fetch` and not
  stored; `put` of one also removes the old value. `put` is a removal then a
  store, not atomic: a reader may see a miss between.
- `ttl_ms`: an entry is never read more than that long after its write (a
  read does not renew it). `get` drops an expired entry; `cleanup` removes all
  expired entries and returns how many (run it in a task: `while true`,
  `Cache.cleanup`, `Task.sleep(5_000)`). Generations also turn by time, but
  only on writes: with no puts, expired entries stay in memory until read or
  `cleanup`. `clock` is for tests.
- `bytes` is never above `max_bytes`.
- Another implementation returns a `Cache.Store` with the same seven
  functions: an expired entry is a miss, a too-big `put` drops the old value,
  `cleanup` gives 0 without a ttl, `bytes` counts as `max_bytes`. Each field
  is a lambda that holds the state, `get: ->(key) { table_get(table, key) }`
  (full example on the site page).
