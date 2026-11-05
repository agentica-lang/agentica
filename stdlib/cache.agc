## A cache that tasks on any scheduler share, as a small contract plus one implementation built on `ATS`.
##
## A `Store` is a struct of function values, the contract every cache implements: Agentica has no traits, so an
## implementation (here `memory`, elsewhere a package with another eviction strategy) builds a `Store` and the helpers
## of this module (`get`, `put`, `fetch` and the rest) work on any of them.
##
## `memory` keeps three tables and treats them as generations. New entries go to the young generation; when it is full
## the cache moves on to the next one and the oldest is dropped whole. A read that finds a key in the previous
## generation copies it forward, so keys that are read stay. Every entry carries an id, and whoever removes it must win
## that id with `ATS.add` first, so its bytes are given back exactly once however the removals race.

# Generation g lives in tables[g % SLOTS]: the young one is g, the old one g - 1, and the slot of g - 2 is dead until
# the next rotation empties and reuses it.
SLOTS = 3
# What an entry costs besides its key and value (the table node), so many tiny entries are bounded too.
ENTRY_OVERHEAD = 64
# A task that holds a rotation for longer than this is taken to have died (cancelled or crashed): another may redo it.
ROTATION_LEASE_MS = 2_000
# The most that a removal waits for the task that is taking out the same entry, in yields and then in milliseconds.
TAKE_WAITS = 60
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
  ## The time in milliseconds, which only has to go forward; the default is the monotonic clock. A test gives a fake.
  clock: Optional[Fn[Int]] = none
end

struct Entry
  value: String
  at: Int
  id: Int
  gen: Int
  src: Int
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

  return Store(
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
export def get(cache: Store, key: String) -> Optional[String]
  return cache.get.call(key)
end

## Returns the value of `key`. On a miss it runs the block and stores its result, then returns it. Two tasks that miss
## together both run the block; one result is kept. A value that the cache refuses is returned and not stored.
export def fetch(cache: Store, key: String, compute: Fn[String]) -> String
  case get(cache, key)
    some(value) -> return value
    none -> return fetched(cache, key, compute.call())
  end
end

## Stores `value` under `key`, replacing a value already there.
export def put(cache: Store, key: String, value: String) -> Void
  cache.put.call(key, value)
end

## Stores `value` under `key` only when the key has none. Returns true when it stored it.
export def put_new(cache: Store, key: String, value: String) -> Bool
  return cache.put_new.call(key, value)
end

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
export def cleanup(cache: Store) -> Int
  return cache.cleanup.call()
end

## Returns how many bytes the entries take, never above `max_bytes` in `memory`.
export def bytes(cache: Store) -> Int
  return cache.bytes.call()
end

# A block is a value only when it is passed to a call, and the cache needs blocks that hold its state: these hand one
# back.
def block0[R](f: Fn[R]) -> Fn[R]
  return f
end

def block1[A, R](f: Fn[A, R]) -> Fn[A, R]
  return f
end

def block2[A, B, R](f: Fn[A, B, R]) -> Fn[A, B, R]
  return f
end

def fetched(cache: Store, key: String, value: String) -> String
  _ = put_new(cache, key, value)
  return value
end

def monotonic_ms() -> Int
  return Time.monotonic_ms
end

def max_of(a: Int, b: Int) -> Int
  if a > b
    return a
  end

  return b
end

def min_of(a: Int, b: Int) -> Int
  if a < b
    return a
  end

  return b
end

# The time of the clock, read only when entries expire.
def now(state: Memory) -> Int
  if state.ttl_ms > 0
    return state.clock.call()
  end

  return 0
end

def expired?(state: Memory, entry: Entry, at: Int) -> Bool
  return state.ttl_ms > 0 and at - entry.at >= state.ttl_ms
end

def current(state: Memory) -> Int
  # memory puts key 0 and nothing deletes it.
  return state.generation.get(0).unwrap!
end

def slot(state: Memory, g: Int) -> ATS[String, Entry]
  return state.tables[(g + SLOTS) % SLOTS]
end

def live_in(state: Memory, g: Int) -> ATS[Int, Int]
  return state.lives[(g + SLOTS) % SLOTS]
end

def cost(key: String, value: String) -> Int
  return ENTRY_OVERHEAD + key.bytesize + value.bytesize
end

def lookup(state: Memory, key: String) -> Optional[String]
  g = current(state)
  at = now(state)
  young = slot(state, g).get(key)
  if young.ok?
    entry = young.unwrap!
    if entry.gen == g and not expired?(state, entry, at) and not orphan?(state, key, entry, g)
      return some(entry.value)
    end

    _ = remove_entry(state, key, entry)
    if entry.gen == g
      return none
    end
  end

  old = slot(state, g - 1).get(key)
  if not old.ok?
    return none
  end

  entry = old.unwrap!
  if entry.gen != g - 1 or expired?(state, entry, at)
    _ = remove_entry(state, key, entry)
    return none
  end

  # The copy keeps the age of the entry, so a read does not make a value live longer.
  _ = insert(state, key, entry.value, entry.at, some(entry))
  return some(entry.value)
end

# A copy that a read made from the old generation is valid while the entry it was made from is still in the old one. A
# removal of the key takes the old entry first, so a copy that lands after the removal is never seen: it is a miss, and
# the read that finds it takes it out. Once a rotation has turned the copy old it stands on its own.
def orphan?(state: Memory, key: String, entry: Entry, g: Int) -> Bool
  if entry.src == 0 or entry.gen != g
    return false
  end

  found = slot(state, g - 1).get(key)
  return not (found.ok? and found.unwrap!.id == entry.src)
end

def write_new(state: Memory, key: String, value: String) -> Bool
  case lookup(state, key)
    some(_) -> return false
    none -> return insert(state, key, value, now(state), none)
  end
end

def write(state: Memory, key: String, value: String) -> Void
  remove(state, key)
  if insert(state, key, value, now(state), none)
    return
  end

  # The key may have been taken by a task that wrote it between the removal and the insert; the later write wins.
  remove(state, key)
  _ = insert(state, key, value, now(state), none)
end

def remove(state: Memory, key: String) -> Void
  g = current(state)
  # The old generation goes first: a copy-forward that is racing with this removal then either sees the old entry gone
  # and takes its copy back out, or has put its copy in the young generation before this reaches it.
  for gen in [g - 1, g]
    found = slot(state, gen).get(key)
    if found.ok?
      _ = remove_entry(state, key, found.unwrap!)
    end
  end
end

# Stores a new entry in the young generation unless the key is taken. Returns whether it did. Space is reserved first
# and given back by the same task when the entry is not stored. `source` is the old-generation entry that a read is
# copying forward: that copy never rotates (a read does not drop a generation), and it is taken back out when the
# source is gone, or the generation moved, by the time it is in, because a removal of the key may have passed it by.
def insert(state: Memory, key: String, value: String, at: Int, source: Optional[Entry]) -> Bool
  size = cost(key, value)
  if size > state.byte_limit
    return false
  end

  if not source.some?
    turn_if_due(state)
  end

  g = reserve(state, size, not source.some?)
  if g < 0
    return false
  end

  id = state.ids.add(0, 1)
  src = 0
  if source.some?
    src = source.unwrap!.id
  end

  entry = Entry(value: value, at: at, id: id, gen: g, src: src)
  live = live_in(state, g)
  live.put(id, size)
  if not slot(state, g).put_new(key, entry)
    live.delete(id)
    give_back(state, g, size)
    return false
  end

  # A task that stalled for two rotations wrote into a table the cache has reused, where its entry is not counted. It
  # removes the entry itself. A task that reads the generation as at most one behind is safe: the rotation that empties
  # its table starts only after the next one is published, which is after this read.
  if current(state) - g >= 2 or (source.some? and not copy_valid?(state, key, g, source.unwrap!))
    _ = remove_entry(state, key, entry)
  end

  return true
end

# A copy is good when the generation it went into is still the young one and the entry it was copied from is still in
# the old one. A copy that is one generation late would go into the old generation, where nothing checks it.
def copy_valid?(state: Memory, key: String, g: Int, source: Entry) -> Bool
  if current(state) != g
    return false
  end

  return still_in?(state, key, source)
end

# Takes an entry that was read out of its table. The task whose add of the entry's size to its id makes 0 is the only
# one that gives the bytes back; the others find the entry already taken. An entry can be put in a table only while its
# key is free, so the entry is still there when the winner takes it out. Returns whether this task took it.
def remove_entry(state: Memory, key: String, entry: Entry) -> Bool
  size = cost(key, entry.value)
  live = live_in(state, entry.gen)
  if entry.gen <= current(state) - 2
    # An entry of a generation that is gone: a task that stalled wrote it after its table was emptied and reused, so
    # neither its id nor its bytes are counted any more. It only has to go.
    live.delete(entry.id)
    take_out(state, key, entry)
    return false
  end

  won = live.add(entry.id, -size) == 0
  live.delete(entry.id)
  if not won
    # Another task has the entry and is about to take it out; a delete that returns before that would leave the key
    # readable. The wait is short and has an end, in case that task was cancelled.
    for n in 1..TAKE_WAITS
      if not still_in?(state, key, entry)
        break
      end

      Task.sleep(min_of(n / 10, 1))
    end

    return false
  end

  take_out(state, key, entry)
  give_back(state, entry.gen, size)
  return true
end

def still_in?(state: Memory, key: String, entry: Entry) -> Bool
  found = slot(state, entry.gen).get(key)
  return found.ok? and found.unwrap!.id == entry.id
end

def take_out(state: Memory, key: String, entry: Entry) -> Void
  if still_in?(state, key, entry)
    slot(state, entry.gen).delete(key)
  end
end

# Reserves one entry of `size` bytes in generation g. The size is checked before it is added, so the count passes the
# limit only when tasks reserve at the same instant, and the task that finds it over takes its reservation back.
def fits?(state: Memory, g: Int, size: Int) -> Bool
  if state.stored.get(g).unwrap_or(0) + size > state.byte_limit
    return false
  end

  taken = state.stored.add(g, size)
  entries = 0
  if state.entry_limit > 0
    entries = state.counted.add(g, 1)
  end

  if taken <= state.byte_limit and (state.entry_limit == 0 or entries <= state.entry_limit)
    return true
  end

  give_back(state, g, size)
  return false
end

def give_back(state: Memory, g: Int, size: Int) -> Void
  state.stored.add(g, -size)
  if state.entry_limit > 0
    state.counted.add(g, -1)
  end
end

# Returns the generation that now holds `size` more bytes, or -1 when there is no room. A full generation rotates once
# when `may_rotate`; a task that finds another rotation going gives up, since a cache may drop an entry.
def reserve(state: Memory, size: Int, may_rotate: Bool) -> Int
  g = current(state)
  if fits?(state, g, size)
    return g
  end

  if not may_rotate
    return -1
  end

  _ = rotate(state, g)
  moved = current(state)
  if moved != g and fits?(state, moved, size)
    return moved
  end

  return -1
end

# With a time to live, a generation that has been young for half of it is dropped when the next one is due, so no entry
# outlives the time to live by more than a generation or two even if nobody reads it. Only writes get here.
def turn_if_due(state: Memory) -> Void
  if state.ttl_ms <= 0
    return
  end

  g = current(state)
  if now(state) - state.started.get(g).unwrap_or(0) >= max_of(state.ttl_ms / 2, 1)
    _ = rotate(state, g)
  end
end

# Moves from generation g to g + 1 when this task wins the right to: it empties the table that g + 1 reuses, which no
# reader looks at, then publishes. Returns whether this task published.
def rotate(state: Memory, g: Int) -> Bool
  token = claim(state, g)
  if token == 0
    return false
  end

  empty_slot(state, g + 1, g)
  # Keys of long dead generations: nothing reads them, and they would pile up.
  for table in [state.started, state.rotations, state.beats, state.stored, state.counted]
    table.delete(g - 3)
  end

  if state.ttl_ms > 0
    state.started.put(g + 1, now(state))
  end

  # A task whose rotation was taken over, because it stood still for the whole lease, finds it is no longer the owner.
  if current(state) == g and state.rotations.get(g).unwrap_or(0) == token
    state.generation.put(0, g + 1)
    return true
  end

  return false
end

# Empties the table and the ids of the slot of generation `dead`, beating the heart of the rotation from g as it goes.
def empty_slot(state: Memory, dead: Int, g: Int) -> Void
  table = slot(state, dead)
  count = 0
  for key in table.keys
    table.delete(key)
    count += 1
    beat_often(state, g, count)
  end

  live = live_in(state, dead)
  for id in live.keys
    live.delete(id)
    count += 1
    beat_often(state, g, count)
  end
end

def beat_often(state: Memory, g: Int, count: Int) -> Void
  if count % BEAT_EVERY == 0
    state.beats.put(g, Time.monotonic_ms)
  end
end

# The right to rotate from generation g, as a token, or 0. Only the rotation from the current generation can
# be started.
# The owner beats while it works; a rotation whose owner has not beaten for the lease is taken over by the one task
# that wins `deaths.add` on its token, so two tasks never take over the same dead owner.
def claim(state: Memory, g: Int) -> Int
  if current(state) != g
    return 0
  end

  token = state.ids.add(0, 1)
  at = Time.monotonic_ms
  if state.rotations.put_new(g, token)
    state.beats.put(g, at)
    return token
  end

  owner = state.rotations.get(g).unwrap_or(0)
  if owner > 0 and at - state.beats.get(g).unwrap_or(at) > ROTATION_LEASE_MS and state.deaths.add(owner, 1) == 1
    state.beats.put(g, at)
    state.rotations.put(g, token)
    return token
  end

  return 0
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
  if state.ttl_ms <= 0
    return 0
  end

  g = current(state)
  at = now(state)
  removed = 0
  for gen in [g, g - 1]
    table = slot(state, gen)
    for key in table.keys
      found = table.get(key)
      if found.ok? and expired?(state, found.unwrap!, at) and remove_entry(state, key, found.unwrap!)
        removed += 1
      end
    end
  end

  return removed
end

# The counts of a generation can pass its limit for an instant, while tasks that found it full take their reservation
# back, so each is read as at most the limit.
def held(state: Memory) -> Int
  g = current(state)
  return (
    min_of(state.stored.get(g).unwrap_or(0), state.byte_limit) +
    min_of(state.stored.get(g - 1).unwrap_or(0), state.byte_limit)
  )
end
