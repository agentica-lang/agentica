## A bounded cache of strings that tasks on any scheduler share, built on `ATS`.
##
## The cache keeps three tables and treats them as generations. New entries go to the young generation; when it is
## full the cache moves on to the next one and the oldest is dropped whole. A read that finds a key in the previous
## generation copies it forward, so keys that are read stay. The bytes of a generation are counted when an entry is
## stored and never taken back, so no race can make the count drift: the count only goes away with its generation.

# Generation g lives in tables[g % SLOTS]: the young one is g, the old one g - 1, and the slot of g - 2 is dead until
# the next rotation empties and reuses it.
SLOTS = 3
# What an entry costs besides its key and value (the table node), so many tiny entries are bounded too.
ENTRY_OVERHEAD = 64
# A task that holds a rotation for longer than this is taken to have died (cancelled or crashed): another may redo it.
ROTATION_LEASE_MS = 2_000

## A cache. Build one with `new`; passing it to a task shares it.
export struct Store
  limit: Int
  tables: List[ATS[String, String]]
  generation: ATS[Int, Int]
  stored: ATS[Int, Int]
  rotations: ATS[Int, Int]
end

## Returns an empty cache that holds at most `max_bytes` bytes of keys, values and entry overhead (64 bytes an entry).
## Each of the two live generations may hold half of it; an entry larger than that is never stored.
export def new(max_bytes: Int) -> Store
  tables: List[ATS[String, String]] = []
  for _ in 1..SLOTS
    table: ATS[String, String] = ATS.new()
    tables = tables.push(table)
  end

  generation: ATS[Int, Int] = ATS.new()
  generation.put(0, 0)
  stored: ATS[Int, Int] = ATS.new()
  rotations: ATS[Int, Int] = ATS.new()
  return Store(limit: max_bytes / 2, tables: tables, generation: generation, stored: stored, rotations: rotations)
end

## Returns the value of `key`, or `none`.
export def get(cache: Store, key: String) -> Optional[String]
  g = current(cache)
  young = slot(cache, g).get(key)
  if young.ok?
    return some(young.unwrap!)
  end

  old = slot(cache, g - 1).get(key)
  if not old.ok?
    return none
  end

  value = old.unwrap!
  _ = store(cache, key, value, false)
  return some(value)
end

## Returns the value of `key`. On a miss it runs the block and stores its result, then returns it. Two tasks that miss
## together both run the block; one result is kept. A value over half of `max_bytes` is returned and not stored.
export def fetch(cache: Store, key: String, compute: Fn[String]) -> String
  case get(cache, key)
    some(value) -> return value
    none -> return stored_value(cache, key, compute.call())
  end
end

## Stores `value` under `key`, replacing a value already there. Replacing does not give the old bytes back until its
## generation is dropped. A value over half of `max_bytes` is not stored.
export def put(cache: Store, key: String, value: String) -> Void
  _ = store(cache, key, value, true)
end

## Removes `key`. The bytes stay counted until their generation is dropped.
export def delete(cache: Store, key: String) -> Void
  g = current(cache)
  slot(cache, g).delete(key)
  slot(cache, g - 1).delete(key)
end

## Removes every entry and starts the byte count again. Tasks that put at the same moment may keep an entry.
export def clear(cache: Store) -> Void
  moved = 0
  while moved < SLOTS
    if rotate(cache, current(cache))
      moved = moved + 1
    else
      Task.sleep(1)
    end
  end
end

## Returns how many bytes the two live generations have taken, an upper bound of what the cache holds.
export def bytes(cache: Store) -> Int
  g = current(cache)
  return stored_in(cache, g) + stored_in(cache, g - 1)
end

def stored_value(cache: Store, key: String, value: String) -> String
  _ = store(cache, key, value, false)
  return value
end

def current(cache: Store) -> Int
  # new puts key 0 and nothing deletes it.
  return cache.generation.get(0).unwrap!
end

def slot(cache: Store, g: Int) -> ATS[String, String]
  return cache.tables[(g + SLOTS) % SLOTS]
end

def stored_in(cache: Store, g: Int) -> Int
  return cache.stored.get(g).unwrap_or(0)
end

# Keeps one entry in the young generation. Space is reserved first and given back by the same task when the entry is
# not stored, so every add has its own matching take-back or an entry behind it. Returns whether the value was kept.
def store(cache: Store, key: String, value: String, replace: Bool) -> Bool
  size = ENTRY_OVERHEAD + key.bytesize + value.bytesize
  if size > cache.limit
    return false
  end

  g = reserve(cache, size)
  if g < 0
    return false
  end

  table = slot(cache, g)
  kept = true
  if replace
    table.put(key, value)
  else
    kept = table.put_new(key, value)
  end

  if not kept
    cache.stored.add(g, -size)
  end

  # A task that stalled for two rotations wrote into a table the cache has reused. Its entry is not counted there, so
  # it takes the entry back out. A task that reads the generation as at most one behind is safe: the rotation that
  # empties its table starts only after the next one is published, which is after this read.
  if current(cache) - g >= 2
    table.delete(key)
  end

  return kept
end

# Returns the generation that now holds `size` more bytes, or -1 when there is no room. A full generation rotates once;
# a task that finds another rotation going gives up, since a cache may drop an entry.
def reserve(cache: Store, size: Int) -> Int
  g = current(cache)
  if cache.stored.add(g, size) <= cache.limit
    return g
  end

  cache.stored.add(g, -size)
  if rotate(cache, g)
    g = g + 1
  elsif current(cache) == g
    return -1
  else
    g = current(cache)
  end

  if cache.stored.add(g, size) <= cache.limit
    return g
  end

  cache.stored.add(g, -size)
  return -1
end

# Moves from generation g to g + 1 when this task wins the right to: it empties the table that g + 1 reuses, which no
# reader looks at, then publishes. Returns false when another task has the rotation.
def rotate(cache: Store, g: Int) -> Bool
  if not claim?(cache, g)
    return false
  end

  table = slot(cache, g + 1)
  for key in table.keys
    table.delete(key)
  end

  # The check keeps a slow task, whose lease was taken over, from moving the generation back.
  if current(cache) == g
    cache.generation.put(0, g + 1)
  end

  return true
end

def claim?(cache: Store, g: Int) -> Bool
  now = Time.monotonic_ms
  if cache.rotations.put_new(g, now)
    return true
  end

  started = cache.rotations.get(g).unwrap_or(now)
  if now - started > ROTATION_LEASE_MS
    cache.rotations.put(g, now)
    return true
  end

  return false
end
