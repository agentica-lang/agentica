# Profile.steps counts the steps of the running task. It works without the profile and repeats exactly: the same
# work costs the same steps, more work costs more, two reads in a row differ by a few steps, and a new task starts
# from its own count.
def work(n: Int) -> Int
  total = 0
  i = 0
  while i < n
    total += i
    i += 1
  end
  return total
end

def cost(n: Int) -> Int
  before = Profile.steps()
  work(n)
  return Profile.steps() - before
end

def own_count(n: Int) -> Int
  return Profile.steps()
end

def main() -> Void
  first = Profile.steps()
  second = Profile.steps()
  puts(first > 0)
  puts(second >= first and second - first < 10)
  puts(cost(100) == cost(100))
  puts(cost(200) > cost(100))
  work(1000)
  t = Task.spawn(&own_count, 0)
  puts(Task.await(t) < Profile.steps())
  inside = Profile.measure("steps") do Profile.steps() end
  puts(inside > second)
end
