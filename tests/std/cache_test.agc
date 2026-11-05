import Cache from "std/cache"

struct Job
  cache: Cache.Store
  computed: ATS[String, Int]
  keys: Int
end

def value_of(key: String) -> String
  return "value of #{key}"
end

# An entry costs the 64 bytes of overhead, its key and its value.
def entry_cost(key: String) -> Int
  return 64 + key.bytesize + value_of(key).bytesize
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

def run_tasks(job: Job, count: Int) -> Int
  tasks = (1..count).to_a.map do |_| Task.spawn(&fetch_all, job) end
  return tasks.map do |task| Task.await(task) end.sum
end

def main() -> Void
  Test.run([
    Test.test("a stored value is a hit and an unknown key a miss") do
      cache = Cache.new(10_000)
      Cache.put(cache, "a", "one")
      try Test.eq(Cache.get(cache, "a"), some("one"))
      Test.eq(Cache.get(cache, "b"), none)
    end,
    Test.test("fetch runs the block on a miss only") do
      cache = Cache.new(10_000)
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
    Test.test("put replaces a value and delete removes it") do
      cache = Cache.new(10_000)
      Cache.put(cache, "a", "one")
      Cache.put(cache, "a", "two")
      try Test.eq(Cache.get(cache, "a"), some("two"))
      Cache.delete(cache, "a")
      try Test.eq(Cache.get(cache, "a"), none)
      Cache.delete(cache, "a")
      Test.eq(Cache.get(cache, "a"), none)
    end,
    Test.test("clear removes every entry and the count") do
      cache = Cache.new(10_000)
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
      cache = Cache.new(4_000)
      for n in 0...200
        key = "k#{n}"
        Cache.put(cache, key, value_of(key))
        try Test.assert(Cache.bytes(cache) <= 4_000, "over the budget after #{key}")
      end
      try Test.eq(Cache.get(cache, "k0"), none)
      Test.eq(Cache.get(cache, "k199"), some(value_of("k199")))
    end,
    Test.test("a key that is read stays through the rotations") do
      cache = Cache.new(4_000)
      Cache.put(cache, "hot", "kept")
      for n in 0...200
        key = "k#{n}"
        Cache.put(cache, key, value_of(key))
        try Test.eq(Cache.get(cache, "hot"), some("kept"))
      end
      Test.eq(Cache.get(cache, "k0"), none)
    end,
    Test.test("a value over half the budget is returned and not stored") do
      cache = Cache.new(1_000)
      big = "x" * 600
      try Test.eq(Cache.fetch(cache, "big") do big end, big)
      try Test.eq(Cache.get(cache, "big"), none)
      try Test.eq(Cache.bytes(cache), 0)
      Cache.put(cache, "small", "ok")
      Test.eq(Cache.get(cache, "small"), some("ok"))
    end,
    Test.test("bytes counts an entry once when tasks fetch the same keys together") do
      keys = 300
      cache = Cache.new(10_000_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: keys)
      try Test.eq(run_tasks(job, 8), 0)
      expected = (0...keys).to_a.map do |n| entry_cost("k#{n}") end.sum
      Test.eq(Cache.bytes(cache), expected)
    end,
    Test.test("many tasks on a small budget get right values and hold the budget") do
      cache = Cache.new(20_000)
      computed: ATS[String, Int] = ATS.new()
      job = Job(cache: cache, computed: computed, keys: 400)
      try Test.eq(run_tasks(job, 8), 0)
      try Test.assert(Cache.bytes(cache) <= 20_000, "over the budget")
      try Test.assert(Cache.bytes(cache) > 0, "nothing was kept")
      Cache.clear(cache)
      Test.eq(Cache.bytes(cache), 0)
    end,
  ])
end
