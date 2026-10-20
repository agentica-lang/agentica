# Profile.measure runs its block once and gives back what the block gives, with the profile off as here: a plain value,
# a Result from a block that uses try, a function value, nested and recursive measures, a block inside List.map, a
# block in a task, and a runtime error inside a measure, which ends that task and leaves later measures working.
struct Point
  x: Int
  y: Int
end

def parse(text: String) -> Result[Int]
  n = try String.to_int(text)
  return ok(n)
end

def seven() -> Int
  return 7
end

def depth(n: Int) -> Int
  return Profile.measure("depth") do
    if n == 0
      return 0
    end
    depth(n - 1) + 1
  end
end

def sum_parsed(texts: List[String]) -> Result[Int]
  return Profile.measure("sum") do
    total = 0
    for text in texts
      total += try parse(text)
    end
    ok(total)
  end
end

def in_task(n: Int) -> Int
  return Profile.measure("task") do n * 10 end
end

def crash(xs: List[Int]) -> Result[Int]
  return Profile.measure("crash") do
    ok(xs[5])
  end
end

def main() -> Void
  puts(Profile.measure("int") do 1 + 2 end)
  puts(Profile.measure("text") do "a" + "b" end)
  p = Profile.measure("point") do Point(x: 1, y: 2) end
  puts(p.x + p.y)
  puts(Profile.measure("fn", &seven))
  both = Profile.measure("outer") do
    a = Profile.measure("inner") do 4 end
    b = Profile.measure("inner") do 5 end
    a * b
  end
  puts(both)
  puts(depth(30))
  good = sum_parsed(["1", "2", "3"])
  puts(good.unwrap_or(-1))
  bad = sum_parsed(["1", "x", "3"])
  puts(bad.ok?)
  puts([1, 2, 3].map do |n| Profile.measure("map") do n * n end end)
  t = Task.spawn(&in_task, 4)
  puts(Task.await(t))
  failed = Task.spawn(&crash, [1, 2])
  outcome = Task.await(failed)
  puts(outcome.ok?)
  puts(Profile.measure("after") do depth(3) end)
end
