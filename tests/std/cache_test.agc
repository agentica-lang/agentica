import Cache from "std/cache"

struct Race
  cache: Cache.Store
  stop: ATS[Int, Int]
end

struct Job
  cache: Cache.Store
  computed: ATS[String, Int]
  keys: Int
  now: ATS[Int, Int]
end

struct Gate
  holder: Channel[Cache.Store]
  to_owner: Channel[Int]
  to_writer: Channel[Int]
  done: Channel[Bool]
end

def value_of(key: String) -> String
  return "value of #{key}"
end

# An entry costs the 64 bytes of overhead, its key and its value.
def entry_cost(key: String) -> Int
  return 64 + key.bytesize + value_of(key).bytesize
end

# The clock of a test is the number in `now`.
def ticking(now: ATS[Int, Int], ttl_ms: Int) -> Cache.Options
  return Cache.Options(ttl_ms: ttl_ms, clock: some(-> { now.get(0).unwrap! }))
end

def tick(now: ATS[Int, Int], ms: Int) -> Void
  now.add(0, ms)
end

def clock() -> ATS[Int, Int]
  now: ATS[Int, Int] = ATS.new()
  now.put(0, 0)
  return now
end

def table_get(table: ATS[String, String], key: String) -> Optional[String]
  found = table.get(key)
  if found.ok?
    return some(found.unwrap!)
  end

  return none
end

def table_clear(table: ATS[String, String]) -> Void
  table.clear
end

# A cache of our own over one table, with no limit: it shows that the helpers need only the struct.
def table_cache() -> Cache.Store
  table: ATS[String, String] = ATS.new()
  return Cache.Store(
    get: ->(key) { table_get(table, key) },
    put: ->(key, value) { table.put(key, value) },
    put_new: ->(key, value) { table.put_new(key, value) },
    delete: ->(key) { table.delete(key) },
    clear: -> { table_clear(table) },
    cleanup: -> { 0 },
    bytes: -> { table.size },
  )
end

# Fetches every key (7 is no factor of the key counts used) and counts a value that is not the one its key stands for.
def fetch_all(job: Job) -> Int
  wrong = 0
  for n in 0...job.keys
    key = "k#{n * 7 % job.keys}"
    got = Cache.fetch(job.cache, key) do
      job.computed.add(key, 1)
      value_of(key)
    end

    if got != value_of(key)
      wrong = wrong + 1
    end
  end
  return wrong
end

# Puts, put_news, deletes and fetches the same few keys from every task; the clock of the test runs on.
def churn(job: Job) -> Int
  wrong = 0
  for n in 0...600
    tick(job.now, 1)
    key = "k#{n * 7 % job.keys}"
    step = n % 4
    if step == 0 and Cache.fetch(job.cache, key) do value_of(key) end != value_of(key)
      wrong = wrong + 1
    elsif step == 1
      Cache.put(job.cache, key, value_of(key))
    elsif step == 2
      Cache.delete(job.cache, key)
    elsif step == 3
      _ = Cache.put_new(job.cache, key, value_of(key))
    end
  end
  return wrong
end

# The clock of the takeover tests: key 0 of `now` is the time. Once key 1 is set, the fourth read moves the time past
# the two-second lease of a rotation, tells the test, and waits, so the test can cancel the task there. It depends on
# the order in which the cache reads its clock in a put that rotates: the lookup, the age of the generation, the claim
# of the rotation and then the owner's read after it checked that it owns the rotation and before it empties the slot.
# For a put that takes a rotation over, the fourth read is the one after it won the takeover and before it writes its
# token.
def takeover_clock(now: ATS[Int, Int], gate: Gate) -> Int
  if now.get(1).unwrap_or(0) == 1 and now.add(3, 1) == 4
    now.put(1, 0)
    now.put(3, 0)
    tick(now, 3_000)
    _ = gate.to_owner.send(1, 0)
    _ = gate.to_writer.recv(60_000)
  end

  return now.get(0).unwrap!
end

# The clock of the late owner test: key 0 of `now` is the time. Once key 1 is set, it counts the reads (key 3) of a
# put that rotates. Read 4 is the owner's, as in takeover_clock: the time moves past the lease, a writer task starts,
# and the owner waits. The writer takes the rotation over and publishes, and its read 10 is between the two writes of
# its entry (the id, then the entry): it lets the owner go on and waits. The owner empties the slot, which now holds
# the young generation, and its read 11, in its own insert, lets the writer store its entry.
def late_clock(now: ATS[Int, Int], gate: Gate) -> Int
  if now.get(1).unwrap_or(0) == 1
    read = now.add(3, 1)
    if read == 4
      tick(now, 3_000)
      cache = gate.holder.recv(0).unwrap!
      _ = gate.holder.send(cache, 0)
      _ = Task.spawn do
        _ = gate.done.send(Cache.put_new(cache, "victim", "v"), 0)
      end

      _ = gate.to_owner.recv(5_000)
    elsif read == 10
      _ = gate.to_owner.send(1, 0)
      _ = gate.to_writer.recv(5_000)
    elsif read == 11
      now.put(1, 0)
      _ = gate.to_writer.send(1, 0)
    end
  end

  return now.get(0).unwrap!
end

def clean_often(job: Job) -> Int
  removed = 0
  for _ in 1..150
    removed = removed + Cache.cleanup(job.cache)
    Task.sleep(0)
  end
  return removed
end

# Readers that get "hot" in batches until `stop` is set. The step budget is shared by all tasks, so they stop after a
# fixed number of batches as well.
def read_hot(race: Race) -> Int
  seen = 0
  for _ in 1..1_500
    if race.stop.get(0).unwrap! == 1
      break
    end

    for _ in 1..5
      seen = seen + Cache.get(race.cache, "hot").unwrap_or("").bytesize
    end

    Task.sleep(0)
  end
  return seen
end

# Puts a new version of "hot" and enough other keys to turn the generations, then deletes it. A get after the put gives
# that version or nothing, and a get after the delete gives nothing; each time it does not counts as wrong.
def write_hot(race: Race) -> Int
  wrong = 0
  for n in 1..150
    version = "v#{n}"
    Cache.put(race.cache, "hot", version)
    got = Cache.get(race.cache, "hot").unwrap_or(version)
    if got != version
      wrong = wrong + 1
    end

    for i in 1..14
      Cache.put(race.cache, "filler#{i}", "x")
    end

    Cache.delete(race.cache, "hot")
    if Cache.get(race.cache, "hot").some?
      wrong = wrong + 1
    end
  end
  race.stop.put(0, 1)
  return wrong
end

def run_tasks(job: Job, count: Int, work: Fn[Job, Int]) -> Int
  tasks = (1..count).to_a.map do |_| Task.spawn(work, job) end
  return tasks.map { |task| Task.await(task) }.sum
end

def main() -> Void
  Test.run([
    Test.test("a stored value is a hit and an unknown key a miss") do
      cache = Cache.memory(10_000)
      Cache.put(cache, "a", "one")
      try Test.eq(Cache.get(cache, "a"), some("one"))
      Test.eq(Cache.get(cache, "b"), none)
    end,
    Test.test("fetch runs the block on a miss only") do
      cache = Cache.memory(10_000)
      calls: ATS[String, Int] = ATS.new()
      first = Cache.fetch(cache, "a") do
        calls.add("a", 1)
        "one"
      end

      second = Cache.fetch(cache, "a") do
        calls.add("a", 1)
        "two"
      end

      try Test.eq([first, second], ["one", "one"])
      Test.eq(calls.get("a"), ok(1))
    end,
    Test.test("put replaces a value, delete removes it, and the bytes follow") do
      cache = Cache.memory(10_000)
      Cache.put(cache, "a", "one")
      try Test.eq(Cache.put_new(cache, "a", "zero"), false)
      Cache.put(cache, "a", "two")
      try Test.eq(Cache.get(cache, "a"), some("two"))
      try Test.eq(Cache.bytes(cache), 64 + 1 + 3)
      Cache.delete(cache, "a")
      try Test.eq(Cache.get(cache, "a"), none)
      try Test.eq(Cache.bytes(cache), 0)
      Cache.delete(cache, "a")
      try Test.eq(Cache.put_new(cache, "a", "three"), true)
      Test.eq(Cache.get(cache, "a"), some("three"))
    end,
    Test.test("clear removes every entry and the count") do
      cache = Cache.memory(10_000)
      Cache.put(cache, "a", "one")
      Cache.put(cache, "b", "two")
      Cache.clear(cache)
      try Test.eq(Cache.get(cache, "a"), none)
      try Test.eq(Cache.get(cache, "b"), none)
      try Test.eq(Cache.bytes(cache), 0)
      Cache.put(cache, "c", "three")
      Test.eq(Cache.get(cache, "c"), some("three"))
    end,
    Test.test("the budget holds under many puts and the oldest keys go first") do
      cache = Cache.memory(4_000)
      for n in 0...200
        key = "k#{n}"
        Cache.put(cache, key, value_of(key))
        try Test.assert(Cache.bytes(cache) <= 4_000, "over the budget after #{key}")
      end
      try Test.eq(Cache.get(cache, "k0"), none)
      Test.eq(Cache.get(cache, "k199"), some(value_of("k199")))
    end,
    Test.test("a value over half the budget is returned and not stored, and drops the old value of its key") do
      cache = Cache.memory(1_000)
      big = "x" * 600
      Cache.put(cache, "k", "small")
      try Test.eq(Cache.get(cache, "k"), some("small"))
      Cache.put(cache, "k", big)
      try Test.eq(Cache.get(cache, "k"), none)
      try Test.eq(Cache.fetch(cache, "big") do big end, big)
      try Test.eq(Cache.get(cache, "big"), none)
      Test.eq(Cache.bytes(cache), 0)
    end,
    Test.test("max_entries bounds the number of entries") do
      cache = Cache.memory(1_000_000, Cache.Options(max_entries: 6))
      for n in 0...50
        Cache.put(cache, "k#{n}", "v")
      end
      kept = (0...50).to_a.select do |n| Cache.get(cache, "k#{n}").unwrap_or("") != "" end
      try Test.assert(kept.size <= 6, "more than 6 entries: #{kept.size}")
      Test.eq(kept.last, 49)
    end,
    Test.test("an entry past its ttl is a miss and gives its bytes back") do
      now = clock()
      cache = Cache.memory(10_000, ticking(now, 100))
      Cache.put(cache, "a", "one")
      tick(now, 99)
      try Test.eq(Cache.get(cache, "a"), some("one"))
      try Test.eq(Cache.put_new(cache, "a", "two"), false)
      tick(now, 1)
      try Test.eq(Cache.get(cache, "a"), none)
      try Test.eq(Cache.bytes(cache), 0)
      try Test.eq(Cache.put_new(cache, "a", "two"), true)
      Test.eq(Cache.get(cache, "a"), some("two"))
    end,
    Test.test("a read does not make a value live longer") do
      now = clock()
      cache = Cache.memory(10_000, ticking(now, 100))
      Cache.put(cache, "a", "one")
      tick(now, 60)
      try Test.eq(Cache.get(cache, "a"), some("one"))
      tick(now, 60)
      Test.eq(Cache.get(cache, "a"), none)
    end,
    Test.test("cleanup removes every expired entry and only those, and gives their bytes back") do
      now = clock()
      cache = Cache.memory(10_000, ticking(now, 100))
      for key in ["a", "b", "c"]
        Cache.put(cache, key, "v")
      end
      tick(now, 60)
      Cache.put(cache, "d", "v")
      tick(now, 40)
      try Test.eq(Cache.cleanup(cache), 3)
      try Test.eq(Cache.bytes(cache), 64 + 1 + 1)
      try Test.eq(Cache.cleanup(cache), 0)
      Test.eq(Cache.get(cache, "d"), some("v"))
    end,
    Test.test("a generation older than the ttl is dropped without a read") do
      now = clock()
      cache = Cache.memory(10_000, ticking(now, 1_000))
      Cache.put(cache, "a", "v")
      tick(now, 600)
      Cache.put(cache, "b", "v")
      tick(now, 600)
      Cache.put(cache, "c", "v")
      Test.eq(Cache.bytes(cache), 2 * (64 + 1 + 1))
    end,
    Test.test("fetch and the helpers work on a cache of any implementation") do
      cache = table_cache()
      try Test.eq(Cache.fetch(cache, "a") do "one" end, "one")
      try Test.eq(Cache.fetch(cache, "a") do "two" end, "one")
      try Test.eq(Cache.put_new(cache, "a", "three"), false)
      Cache.put(cache, "a", "four")
      try Test.eq(Cache.get(cache, "a"), some("four"))
      Cache.delete(cache, "a")
      try Test.eq(Cache.bytes(cache), 0)
      try Test.eq(Cache.cleanup(cache), 0)
      Test.eq(Cache.get(cache, "a"), none)
    end,
    Test.test("bytes counts an entry once when tasks fetch the same keys together") do
      keys = 200
      cache = Cache.memory(10_000_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: keys, now: clock())
      try Test.eq(run_tasks(job, 4, &fetch_all), 0)
      expected = (0...keys).to_a.map { |n| entry_cost("k#{n}") }.sum
      Test.eq(Cache.bytes(cache), expected)
    end,
    Test.test("bytes is exact after tasks put, replace, delete and fetch the same keys together") do
      keys = 50
      cache = Cache.memory(10_000_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: keys, now: clock())
      try Test.eq(run_tasks(job, 4, &churn), 0)
      present = (0...keys).to_a.select do |n| Cache.get(cache, "k#{n}").unwrap_or("") != "" end
      Test.eq(Cache.bytes(cache), present.map { |n| entry_cost("k#{n}") }.sum)
    end,
    Test.test("readers that get a key while it is put and deleted never see a deleted key or an older value") do
      stop: ATS[Int, Int] = ATS.new()
      stop.put(0, 0)
      race = Race(cache: Cache.memory(2_000), stop: stop)
      readers = (1..2).to_a.map do |_| Task.spawn(&read_hot, race) end
      wrong = Task.await(Task.spawn(&write_hot, race))
      readers.each do |reader| _ = Task.await(reader) end
      Test.eq(wrong, 0)
    end,
    Test.test("tasks that rotate the generations while they churn end with exact bytes") do
      keys = 400
      cache = Cache.memory(20_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: keys, now: clock())
      try Test.eq(run_tasks(job, 4, &churn), 0)
      try Test.assert(Cache.bytes(cache) <= 20_000, "over the budget")
      for n in 0...keys
        Cache.delete(cache, "k#{n}")
      end
      Test.eq(Cache.bytes(cache), 0)
    end,
    Test.test("a rotation whose owner was cancelled in the middle is taken over, with exact bytes") do
      now = clock()
      gate = Gate(holder: Channel.new(1), to_owner: Channel.new(1), to_writer: Channel.new(1), done: Channel.new(1))
      options = Cache.Options(max_entries: 4, ttl_ms: 1_000_000_000, clock: some(-> { takeover_clock(now, gate) }))
      cache = Cache.memory(10_000_000, options)
      for n in 0...6
        _ = Cache.put_new(cache, "k#{n}", "v")
      end
      now.put(1, 1)
      owner = Task.spawn do
        _ = Cache.put_new(cache, "last", "v")
      end

      try Test.eq(gate.to_owner.recv(5_000), ok(1))
      Task.cancel(owner)
      for key in ["young1", "young2"]
        try Test.eq(Cache.put_new(cache, key, "v"), true)
        try Test.eq(Cache.get(cache, key), some("v"))
        Cache.delete(cache, key)
      end
      try Test.eq(Cache.get(cache, "last"), none)
      for n in 0...6
        Cache.delete(cache, "k#{n}")
      end
      Test.eq(Cache.bytes(cache), 0)
    end,
    Test.test("a takeover whose task was cancelled in the middle is taken over two leases later") do
      now = clock()
      gate = Gate(holder: Channel.new(1), to_owner: Channel.new(1), to_writer: Channel.new(1), done: Channel.new(1))
      options = Cache.Options(max_entries: 4, ttl_ms: 1_000_000_000, clock: some(-> { takeover_clock(now, gate) }))
      cache = Cache.memory(10_000_000, options)
      for n in 0...6
        _ = Cache.put_new(cache, "k#{n}", "v")
      end
      for key in ["owner", "taker"]
        now.put(1, 1)
        task = Task.spawn do
          _ = Cache.put_new(cache, key, "v")
        end

        try Test.eq(gate.to_owner.recv(5_000), ok(1))
        Task.cancel(task)
      end
      try Test.eq(Cache.put_new(cache, "early", "v"), false)
      tick(now, 2_000)
      try Test.eq(Cache.put_new(cache, "young", "v"), true)
      try Test.eq(Cache.get(cache, "young"), some("v"))
      Cache.clear(cache)
      Test.eq(Cache.bytes(cache), 0)
    end,
    Test.test("a task that stood still for a lease after it won a takeover leaves it to a later task") do
      now = clock()
      gate = Gate(holder: Channel.new(1), to_owner: Channel.new(1), to_writer: Channel.new(1), done: Channel.new(1))
      options = Cache.Options(max_entries: 4, ttl_ms: 1_000_000_000, clock: some(-> { takeover_clock(now, gate) }))
      cache = Cache.memory(10_000_000, options)
      for n in 0...6
        _ = Cache.put_new(cache, "k#{n}", "v")
      end
      now.put(1, 1)
      owner = Task.spawn do
        _ = Cache.put_new(cache, "owner", "v")
      end

      try Test.eq(gate.to_owner.recv(5_000), ok(1))
      Task.cancel(owner)
      now.put(1, 1)
      _ = Task.spawn do
        _ = gate.done.send(Cache.put_new(cache, "late", "v"), 0)
      end

      try Test.eq(gate.to_owner.recv(5_000), ok(1))
      _ = gate.to_writer.send(1, 0)
      try Test.eq(gate.done.recv(5_000), ok(false))
      tick(now, 2_000)
      try Test.eq(Cache.put_new(cache, "young", "v"), true)
      Test.eq(Cache.get(cache, "young"), some("v"))
    end,
    Test.test("an entry stored while a late owner empties its slot is taken out") do
      now = clock()
      gate = Gate(holder: Channel.new(1), to_owner: Channel.new(1), to_writer: Channel.new(1), done: Channel.new(1))
      options = Cache.Options(max_entries: 4, ttl_ms: 1_000_000_000, clock: some(-> { late_clock(now, gate) }))
      cache = Cache.memory(10_000_000, options)
      _ = gate.holder.send(cache, 0)
      for n in 0...6
        _ = Cache.put_new(cache, "k#{n}", "v")
      end
      now.put(1, 1)
      try Test.eq(Cache.put_new(cache, "last", "v"), true)
      try Test.eq(gate.done.recv(5_000), ok(false))
      try Test.eq(now.get(1), ok(0))
      try Test.eq(Cache.get(cache, "victim"), none)
      try Test.eq(Cache.get(cache, "last"), some("v"))
      Cache.put(cache, "victim", "new")
      Cache.delete(cache, "victim")
      Test.eq(Cache.get(cache, "victim"), none)
    end,
    Test.test("many tasks on a small budget get right values and hold the budget") do
      cache = Cache.memory(20_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: 400, now: clock())
      try Test.eq(run_tasks(job, 4, &fetch_all), 0)
      try Test.assert(Cache.bytes(cache) <= 20_000, "over the budget")
      try Test.assert(Cache.bytes(cache) > 0, "nothing was kept")
      Cache.clear(cache)
      Test.eq(Cache.bytes(cache), 0)
    end,
    Test.test("tasks that churn while another cleans up end with no bytes once everything expired") do
      now = clock()
      cache = Cache.memory(20_000, ticking(now, 50))
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: 40, now: now)
      cleaner = Task.spawn(&clean_often, job)
      try Test.eq(run_tasks(job, 4, &churn), 0)
      _ = Task.await(cleaner)
      try Test.assert(Cache.bytes(cache) <= 20_000, "over the budget")
      tick(now, 1_000)
      _ = Cache.cleanup(cache)
      Test.eq(Cache.bytes(cache), 0)
    end,
  ])
end
