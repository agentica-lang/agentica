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

def value_of(key: String) -> String
  return "value of #{key}"
end

# An entry costs the 64 bytes of overhead, its key and its value.
def entry_cost(key: String) -> Int
  return 64 + key.bytesize + value_of(key).bytesize
end

# A block is a value only when it is passed to a call: these return the blocks a cache of ours is made of.
def block0[R](f: Fn[R]) -> Fn[R]
  return f
end

def block1[A, R](f: Fn[A, R]) -> Fn[A, R]
  return f
end

def block2[A, B, R](f: Fn[A, B, R]) -> Fn[A, B, R]
  return f
end

# The clock of a test is the number in `now`.
def ticking(now: ATS[Int, Int], ttl_ms: Int) -> Cache.Options
  return Cache.Options(ttl_ms: ttl_ms, clock: some(block0() do now.get(0).unwrap! end))
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
  for key in table.keys
    table.delete(key)
  end
end

# A cache of our own over one table, with no limit: it shows that the helpers need only the struct.
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

# The clock of the takeover test: key 0 of `now` is the time. Once key 1 is set, the second read moves the time past
# the two-second lease of a rotation and has another task put the keys young1 to young5. The first read is the claim of
# a rotation and the second its beat after 1024 deletes, so the rotation is taken over in its middle: the new owner
# publishes, and the young keys go into the generation it published while the old owner is still emptying.
def takeover_clock(now: ATS[Int, Int], holder: Channel[Cache.Store]) -> Int
  if now.get(1).unwrap_or(0) == 1 and now.add(3, 1) == 2
    now.put(2, 1)
    tick(now, 3_000)
    cache = holder.recv(0).unwrap!
    _ = holder.send(cache, 0)
    Task.await(Task.spawn do
      for i in 1..5
        _ = Cache.put_new(cache, "young#{i}", "v")
      end
    end)
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
  return tasks.map do |task| Task.await(task) end.sum
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
      expected = (0...keys).to_a.map do |n| entry_cost("k#{n}") end.sum
      Test.eq(Cache.bytes(cache), expected)
    end,
    Test.test("bytes is exact after tasks put, replace, delete and fetch the same keys together") do
      keys = 50
      cache = Cache.memory(10_000_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: keys, now: clock())
      try Test.eq(run_tasks(job, 4, &churn), 0)
      present = (0...keys).to_a.select do |n| Cache.get(cache, "k#{n}").unwrap_or("") != "" end
      Test.eq(Cache.bytes(cache), present.map do |n| entry_cost("k#{n}") end.sum)
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
    Test.test("a rotation taken over in the middle leaves the entries of the new generation counted and removable") do
      now = clock()
      holder: Channel[Cache.Store] = Channel.new(1)
      # 1030 entries a generation, so the rotation that drops the first one beats before it is done.
      options = Cache.Options(max_entries: 2_060, clock: some(block0() do takeover_clock(now, holder) end))
      cache = Cache.memory(10_000_000, options)
      _ = holder.send(cache, 0)
      for n in 0...3_090
        _ = Cache.put_new(cache, "k#{n}", "v")
      end
      now.put(1, 1)
      _ = Cache.put_new(cache, "last", "v")
      try Test.eq(now.get(2), ok(1))
      for key in ["last", "young1", "young2", "young3", "young4", "young5"]
        try Test.eq(Cache.get(cache, key), some("v"))
        Cache.delete(cache, key)
      end
      for n in 0...3_090
        Cache.delete(cache, "k#{n}")
      end
      Test.eq(Cache.bytes(cache), 0)
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
