## Tasks that share a cache and a counter through ATS tables: each worker looks
## up the same numbers, the first to miss a number stores its text, and the
## counter adds up every lookup.

struct Shared
  cache: ATS[Int, String]
  stats: ATS[String, Int]
end

def describe(n: Int) -> String
  return "#{n} squared is #{n * n}"
end

def lookup(shared: Shared, n: Int) -> String
  shared.stats.add("lookups", 1)
  found = shared.cache.get(n)
  if found.ok?
    return found.unwrap!
  end

  text = describe(n)
  if shared.cache.put_new(n, text)
    shared.stats.add("stored", 1)
  end

  return text
end

def work(shared: Shared) -> Int
  letters = 0
  for n in 1..6
    letters += lookup(shared, n).length
  end

  return letters
end

def main() -> Void
  cache: ATS[Int, String] = ATS.new()
  stats: ATS[String, Int] = ATS.new()
  shared = Shared(cache: cache, stats: stats)
  workers = [1, 2, 3, 4].map do |_| Task.spawn(&work, shared) end
  letters = workers.map do |worker| Task.await(worker) end
  puts("letters per worker: #{letters.uniq}")
  puts("lookups: #{stats.get("lookups").unwrap_or(0)}")
  puts("stored: #{stats.get("stored").unwrap_or(0)}")
  for n in cache.keys.sort
    puts(cache.get(n).unwrap_or("missing"))
  end
end
