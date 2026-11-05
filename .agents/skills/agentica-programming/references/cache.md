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
  generation is dropped whole when the young one is full, and a `get` copies a
  hit from the old one forward. A value over half of `max_bytes` is returned
  by `fetch` and not stored; `put` of one also removes the old value.
- `ttl_ms` gives each entry that life from its write (a read does not renew
  it). `get` drops an expired entry; `cleanup` removes all expired entries and
  returns how many (run it in a task: `while true`, `Cache.cleanup`,
  `Task.sleep(5_000)`); a generation young for half the ttl is dropped when
  the next put comes. `clock` is for tests (a block that reads a number).
- `bytes` is exact (delete, replace, expiry and `cleanup` give bytes back) and
  never above `max_bytes`. A drop deletes entries one by one: one `put` waits.
- Another implementation returns a `Cache.Store` with the same seven
  functions; a block is a value only when passed to a call, so a helper
  `def block1[A, R](f: Fn[A, R]) -> Fn[A, R]` returns it to hold state.
