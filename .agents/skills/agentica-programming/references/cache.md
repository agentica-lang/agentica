# Cache (`std/cache`)

`import Cache from "std/cache"`. A bounded cache of `String` values on `ATS`,
shared by tasks on any scheduler. Written in Agentica. A store is a handle:
passing it shares it. No methods: `Cache.get(cache, key)`.

```text
Cache.new(max_bytes: Int) -> Cache.Store
Cache.fetch(cache: Cache.Store, key: String, compute: Fn[String]) -> String
Cache.get(cache: Cache.Store, key: String) -> Optional[String]
Cache.put(cache: Cache.Store, key: String, value: String) -> Void
Cache.delete(cache: Cache.Store, key: String) -> Void
Cache.clear(cache: Cache.Store) -> Void
Cache.bytes(cache: Cache.Store) -> Int
```

- `fetch` runs the block on a miss, stores the result and returns it. Tasks
  that miss together may all run the block; one result is kept.
- Keys and values are `String` (`id.to_s` for an `Int` key); there is no
  `Bytes` value and no expiry. Put the version in the key
  (`"msg:#{id}:#{updated_at}"`) instead of deleting.
- An entry costs key + value + 64 bytes. Each of two live generations holds
  half of `max_bytes`; the oldest generation is dropped whole when the young
  one is full, and a `get` copies a hit from the old one forward. A value over
  half of `max_bytes` is returned by `fetch` and not stored.
- `put` over a key and `delete` do not give their bytes back until the
  generation is dropped; `bytes` is an upper bound, never above `max_bytes`.
- A drop deletes keys one by one (about 2 us each): one `put` waits for it.
