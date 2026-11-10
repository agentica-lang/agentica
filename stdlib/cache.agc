## A cache that tasks on any scheduler share, as a small contract plus one implementation built on `ATS`.
##
## A `Store` is a struct of function values, the contract every cache implements: Agentica has no traits, so an
## implementation (here `memory`, elsewhere a package with another eviction strategy) builds a `Store` and the helpers
## of this module (`get`, `put`, `fetch` and the rest) work on any of them.
##
## `memory` keeps three tables and treats them as generations. New entries go to the young generation; when it is full
## the cache moves on to the next one and the oldest is dropped whole. A read writes only to remove an expired entry.
## Every entry carries an id, and whoever removes it must win that id with `ATS.add` first, so its bytes are given back
## exactly once however the removals race.

# Generation g lives in tables[g % SLOTS]: the young one is g, the old one g - 1, and the slot of g - 2 is dead until
# the next rotation empties and reuses it.
SLOTS = 3
# What an entry costs besides its key and value (the table node), so many tiny entries are bounded too.
ENTRY_OVERHEAD = 64
# A task that holds a rotation for longer than this on the cache's clock is taken to have died (cancelled or
# crashed): another may redo it.
ROTATION_LEASE_MS = 2_000
# A rotation shows it is alive after this many deletes.
BEAT_EVERY = 1024

## The contract of a cache. Every function is safe to call from any task at any time. Keys and values are strings.
export struct Store
  ## Gives the value of a key, or `none`; an entry past its time to live is a miss.
  get: Fn[String, Optional[String]]
  ## Stores a value and replaces one already there. A value too big for the cache is not stored and drops the old one.
  put: Fn[String, String, Void]
  ## Stores a value only when the key has none. Gives true when it stored it.
  put_new: Fn[String, String, Bool]
  delete: Fn[String, Void]
  clear: Fn[Void]
  ## Removes every expired entry and gives how many it removed.
  cleanup: Fn[Int]
  ## Gives how many bytes the entries take, counted as `max_bytes` is.
  bytes: Fn[Int]
end

## What `memory` takes besides the byte budget.
export struct Options
  ## At most this many entries, 0 for no limit.
  max_entries: Int = 0
  ## The time to live of an entry in milliseconds, 0 for none.
  ttl_ms: Int = 0
  ## The time in milliseconds, which only has to go forward; the default is the monotonic clock. It times the entries
  ## and the two-second lease of a rotation, so a clock that stops also keeps a stalled rotation from being taken over.
  ## A test gives a fake.
  clock: Optional[Fn[Int]] = none
end

struct Entry
  key: String
  value: String
  at: Int
  id: Int
  gen: Int
end

struct Memory
  byte_limit: Int
  entry_limit: Int
  ttl_ms: Int
  clock: Fn[Int]
  tables: List[ATS[String, Entry]]
  lives: List[ATS[Int, Int]]
  generation: ATS[Int, Int]
  started: ATS[Int, Int]
  rotations: ATS[Int, Int]
  beats: ATS[Int, Int]
  deaths: ATS[Int, Int]
  stored: ATS[Int, Int]
  counted: ATS[Int, Int]
  ids: ATS[Int, Int]
end

## Returns a cache in memory that holds at most `max_bytes` bytes of keys, values and entry overhead (64 bytes an
## entry). Each of the two live generations may hold half of it, and of `max_entries`; a value that would take more
## than half of `max_bytes` is never stored.
export def memory(max_bytes: Int, options: Options = Options()) -> Store
  tables: List[ATS[String, Entry]] = []
  lives: List[ATS[Int, Int]] = []
  for _ in 1..SLOTS
    table: ATS[String, Entry] = ATS.new()
    tables = tables.push(table)
    live: ATS[Int, Int] = ATS.new()
    lives = lives.push(live)
  end

  generation: ATS[Int, Int] = ATS.new()
  generation.put(0, 0)
  started: ATS[Int, Int] = ATS.new()
  rotations: ATS[Int, Int] = ATS.new()
  beats: ATS[Int, Int] = ATS.new()
  deaths: ATS[Int, Int] = ATS.new()
  stored: ATS[Int, Int] = ATS.new()
  counted: ATS[Int, Int] = ATS.new()
  ids: ATS[Int, Int] = ATS.new()
  entry_limit = 0
  if options.max_entries > 0
    entry_limit = max_of(options.max_entries / 2, 1)
  end

  clock = options.clock.unwrap_or(&monotonic_ms)
  state = Memory(
    byte_limit: max_bytes / 2,
    entry_limit: entry_limit,
    ttl_ms: options.ttl_ms,
    clock: clock,
    tables: tables,
    lives: lives,
    generation: generation,
    started: started,
    rotations: rotations,
    beats: beats,
    deaths: deaths,
    stored: stored,
    counted: counted,
    ids: ids,
  )

  if options.ttl_ms > 0
    started.put(0, clock.call())
  end

  Store(
    get: block1() do |key| lookup(state, key) end,
    put: block2() do |key, value| write(state, key, value) end,
    put_new: block2() do |key, value| write_new(state, key, value) end,
    delete: block1() do |key| remove(state, key) end,
    clear: block0() do wipe(state) end,
    cleanup: block0() do sweep(state) end,
    bytes: block0() do held(state) end,
  )
end

## Returns the value of `key`, or `none`.
export def get(cache: Store, key: String) -> Optional[String] = cache.get.call(key)

## Returns the value of `key`. On a miss it runs the block and stores its result, then returns it. Two tasks that miss
## together both run the block; one result is kept. A value that the cache refuses is returned and not stored.
export def fetch(cache: Store, key: String, compute: Fn[String]) -> String
  case get(cache, key)
    some(value) -> value
    none -> fetched(cache, key, compute.call())
  end
end

## Stores `value` under `key`, replacing a value already there.
export def put(cache: Store, key: String, value: String) -> Void
  cache.put.call(key, value)
end

## Stores `value` under `key` only when the key has none. Returns true when it stored it.
export def put_new(cache: Store, key: String, value: String) -> Bool = cache.put_new.call(key, value)

## Removes `key`.
export def delete(cache: Store, key: String) -> Void
  cache.delete.call(key)
end

## Removes every entry. Tasks that put at the same moment may keep an entry.
export def clear(cache: Store) -> Void
  cache.clear.call()
end

## Removes every entry past its time to live and returns how many it removed. It is safe next to any other call, so a
## task may run it every few seconds.
export def cleanup(cache: Store) -> Int = cache.cleanup.call()

## Returns how many bytes the entries take, never above `max_bytes` in `memory`.
export def bytes(cache: Store) -> Int = cache.bytes.call()

# A block is a value only when it is passed to a call, and the cache needs blocks that hold its state: these hand one
# back.
def block0[R](f: Fn[R]) -> Fn[R] = f

def block1[A, R](f: Fn[A, R]) -> Fn[A, R] = f

def block2[A, B, R](f: Fn[A, B, R]) -> Fn[A, B, R] = f

def fetched(cache: Store, key: String, value: String) -> String
  _ = put_new(cache, key, value)
  value
end

def monotonic_ms() -> Int = Time.monotonic_ms

def max_of(a: Int, b: Int) -> Int
  return a if a > b

  b
end

def min_of(a: Int, b: Int) -> Int
  return a if a < b

  b
end

# The time of the clock, read only when entries expire.
def now(state: Memory) -> Int
  return state.clock.call() if state.ttl_ms > 0

  0
end

def expired?(state: Memory, entry: Entry, at: Int) -> Bool = state.ttl_ms > 0 and at - entry.at >= state.ttl_ms

def current(state: Memory) -> Int
  # memory puts key 0 and nothing deletes it.
  state.generation.get(0).unwrap!
end

def slot(state: Memory, g: Int) -> ATS[String, Entry] = state.tables[(g + SLOTS) % SLOTS]

def live_in(state: Memory, g: Int) -> ATS[Int, Int] = state.lives[(g + SLOTS) % SLOTS]

def cost(key: String, value: String) -> Int = ENTRY_OVERHEAD + key.bytesize + value.bytesize

# The key of an entry in its table. A remover reads an entry and then deletes its key, two calls apart; if the table
# were reused in between under the bare key, the delete would drop the newer generation's entry and leave its bytes
# counted. The generation in the key keeps the delete in the old generation.
def slot_key(g: Int, key: String) -> String = "#{g}:#{key}"

def lookup(state: Memory, key: String) -> Optional[String]
  g = current(state)
  at = now(state)
  for gen in [g, g - 1]
    found = slot(state, gen).get(slot_key(gen, key))
    if found.ok?
      entry = found.unwrap!
      return some(entry.value) if not expired?(state, entry, at)

      _ = remove_entry(state, entry)
      return none
    end
  end

  none
end

def write_new(state: Memory, key: String, value: String) -> Bool
  case lookup(state, key)
    some(_) -> false
    none -> insert(state, key, value)
  end
end

def write(state: Memory, key: String, value: String) -> Void
  remove(state, key)
  return if insert(state, key, value)

  # The key may have been taken by a task that wrote it between the removal and the insert; the later write wins.
  remove(state, key)
  _ = insert(state, key, value)
end

def remove(state: Memory, key: String) -> Void
  g = current(state)
  for gen in [g, g - 1]
    found = slot(state, gen).get(slot_key(gen, key))
    if found.ok?
      _ = remove_entry(state, found.unwrap!)
    end
  end
end

# Stores a new entry in the young generation unless the key is taken. Returns whether it did. Space is reserved first
# and given back by the same task when the entry is not stored.
def insert(state: Memory, key: String, value: String) -> Bool
  size = cost(key, value)
  return false if size > state.byte_limit

  turn_if_due(state)
  g = reserve(state, size)
  return false if g < 0

  id = state.ids.add(0, 1)
  entry = Entry(key: key, value: value, at: now(state), id: id, gen: g)
  live = live_in(state, g)
  live.put(id, size)
  if not slot(state, g).put_new(slot_key(g, key), entry)
    live.delete(id)
    give_back(state, g, size)
    return false
  end

  # A task that stalled for two rotations wrote into a table the cache has reused, where its entry is not counted and
  # its id was wiped, so it just takes the entry out. A task that read the generation as at most one behind is safe:
  # the rotation that empties its table starts only after the next one is published, which is after this read.
  if current(state) - g >= 2
    live.delete(id)
    take_out(state, entry)
  end

  true
end

# Takes an entry that was read out of its table. The task whose add of the entry's size to its id makes 0 is the only
# one that gives the bytes back; the others find the entry already taken. An entry can be put in a table only while its
# key in that generation is free, so the entry is still there when the winner takes it out. Returns whether this task
# took it.
def remove_entry(state: Memory, entry: Entry) -> Bool
  size = cost(entry.key, entry.value)
  live = live_in(state, entry.gen)
  won = live.add(entry.id, -size) == 0
  live.delete(entry.id)
  return false if not won

  take_out(state, entry)
  give_back(state, entry.gen, size)
  true
end

def take_out(state: Memory, entry: Entry) -> Void
  table = slot(state, entry.gen)
  key = slot_key(entry.gen, entry.key)
  found = table.get(key)
  if found.ok? and found.unwrap!.id == entry.id
    table.delete(key)
  end
end

def fits?(state: Memory, g: Int, size: Int) -> Bool
  return false if state.stored.get(g).unwrap_or(0) + size > state.byte_limit

  taken = state.stored.add(g, size)
  entries = 0
  if state.entry_limit > 0
    entries = state.counted.add(g, 1)
  end

  return true if taken <= state.byte_limit and (state.entry_limit == 0 or entries <= state.entry_limit)

  give_back(state, g, size)
  false
end

def give_back(state: Memory, g: Int, size: Int) -> Void
  # The counts of a generation that is two behind are gone, and an add would make a key for it that nothing deletes.
  return if g <= current(state) - 2

  state.stored.add(g, -size)
  if state.entry_limit > 0
    state.counted.add(g, -1)
  end
end

# Returns the generation that now holds `size` more bytes, or -1 when there is no room. A full generation rotates once;
# a task that finds another rotation going gives up, since a cache may drop an entry.
def reserve(state: Memory, size: Int) -> Int
  g = current(state)
  return g if fits?(state, g, size)

  _ = rotate(state, g)
  moved = current(state)
  return moved if moved != g and fits?(state, moved, size)

  -1
end

# With a time to live, a generation that has been young for half of it is dropped when the next one is due, so no entry
# outlives the time to live by more than a generation or two even if nobody reads it. Only writes get here.
def turn_if_due(state: Memory) -> Void
  return if state.ttl_ms <= 0

  g = current(state)
  # A generation that a late publish skipped to has no start: it starts now, rather than at 0, which would drop it at
  # once.
  started = state.started.get(g)
  if not started.ok?
    _ = state.started.put_new(g, now(state))
    return
  end

  if now(state) - started.unwrap! >= max_of(state.ttl_ms / 2, 1)
    _ = rotate(state, g)
  end
end

# Moves from generation g to g + 1 when this task wins the right to: it empties the table that g + 1 reuses, which no
# reader looks at, then publishes. Returns whether this task published.
def rotate(state: Memory, g: Int) -> Bool
  before = state.rotations.get(g).unwrap_or(0)
  token = claim(state, g)
  return false if token == 0

  return false if not empty_slot(state, g + 1, g, token)

  # Keys of long dead generations: nothing reads them, and they would pile up. All those up to g - 3 go, not only
  # g - 3, since the rotation from a generation that a late publish skipped never ran. The tables hold a few keys.
  for table in [state.started, state.rotations, state.beats, state.stored, state.counted]
    for key in table.keys
      if key <= g - 3
        table.delete(key)
      end
    end
  end

  if state.ttl_ms > 0
    state.started.put(g + 1, now(state))
  end

  # A task whose rotation was taken over, because it stood still for the whole lease, finds it is no longer the owner.
  # It can still pass this check just before the takeover and publish late, after the new owner did. So the publish
  # adds one rather than putting g + 1, which could move the generation back: a late one skips a generation, whose
  # slot then keeps entries that nothing reads or counts until a later rotation empties it.
  if current(state) == g and state.rotations.get(g).unwrap_or(0) == token
    _ = state.generation.add(0, 1)
    # A takeover is over once the generation moved: no one can claim this rotation again, so the arbiter can go.
    state.deaths.delete(before)
    return true
  end

  false
end

# Empties the table and the ids of the slot of generation `dead`, beating the heart of the rotation from g as it goes.
# Returns false, stopping, when the rotation was taken over: the new owner empties the table. Until this task sees
# that, the new owner may have published and the slot may hold a young generation, so it deletes only what belongs to
# a dead one: a key whose entry is two or more generations behind g (the key names its generation, so the entry read
# is the one deleted), and an id below its token (ids and tokens share one counter, and every entry of a later
# generation draws its id after that generation was published, which is after this rotation was claimed).
def empty_slot(state: Memory, dead: Int, g: Int, token: Int) -> Bool
  return false if current(state) != g

  table = slot(state, dead)
  count = 0
  for key in table.keys
    found = table.get(key)
    if found.ok? and found.unwrap!.gen <= g - 2
      table.delete(key)
    end
    count += 1
    return false if count % BEAT_EVERY == 0 and not beat(state, g, token)
  end

  live = live_in(state, dead)
  for id in live.keys
    if id < token
      live.delete(id)
    end
    count += 1
    return false if count % BEAT_EVERY == 0 and not beat(state, g, token)
  end

  true
end

# Shows that the owner of the rotation from g is alive. Returns false when it is no longer the owner or the generation
# has moved on, since the table it is emptying is then in use.
def beat(state: Memory, g: Int, token: Int) -> Bool
  return false if current(state) != g or state.rotations.get(g).unwrap_or(0) != token

  state.beats.put(g, state.clock.call())
  true
end

# The right to rotate from generation g, as a token, or 0. Only the rotation from the current generation can be
# started. The owner beats while it works; a rotation whose owner has not beaten for the lease is taken over by the one
# task that wins `deaths.add` on its token, so two tasks never take over the same dead owner.
def claim(state: Memory, g: Int) -> Int
  return 0 if current(state) != g

  token = state.ids.add(0, 1)
  at = state.clock.call()
  if state.rotations.put_new(g, token)
    state.beats.put(g, at)
    return token
  end

  owner = state.rotations.get(g).unwrap_or(0)
  if owner > 0 and at - state.beats.get(g).unwrap_or(at) > ROTATION_LEASE_MS and state.deaths.add(owner, 1) == 1
    # The dead owner may have finished while this task decided; nothing has been taken from it yet, so just leave.
    return 0 if current(state) != g

    state.beats.put(g, at)
    state.rotations.put(g, token)
    return token
  end

  0
end

def wipe(state: Memory) -> Void
  moved = 0
  while moved < SLOTS
    if rotate(state, current(state))
      moved += 1
    else
      Task.sleep(1)
    end
  end
end

def sweep(state: Memory) -> Int
  return 0 if state.ttl_ms <= 0

  g = current(state)
  at = now(state)
  removed = 0
  for gen in [g, g - 1]
    table = slot(state, gen)
    for key in table.keys
      found = table.get(key)
      if found.ok? and expired?(state, found.unwrap!, at) and remove_entry(state, found.unwrap!)
        removed += 1
      end
    end
  end

  removed
end

# The counts of a generation can pass its limit for an instant, while tasks that found it full take their reservation
# back, so each is read as at most the limit.
def held(state: Memory) -> Int
  g = current(state)
  (
    min_of(state.stored.get(g).unwrap_or(0), state.byte_limit) +
    min_of(state.stored.get(g - 1).unwrap_or(0), state.byte_limit)
  )
end
