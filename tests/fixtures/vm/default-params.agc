enum Mode
  Fast
  Safe
end

def join(xs: List[String], sep: String = ", ") -> String
  return xs.join(sep)
end

def scale(n: Int, factor: Int = 2, offset: Int = -1, ratio: Float = -0.5, on: Bool = true) -> String
  return "#{n * factor + offset} #{ratio} #{on}"
end

def describe(label: String, mode: Mode = Mode.Safe, tags: List[String] = [], meta: Map[String, Int] = {}) -> String
  return "#{label} #{mode} #{tags.size} #{meta.size}"
end

# The defaults are built at each call: pushing onto one result never shows in the next.
def grow(items: List[Int] = []) -> List[Int]
  return items.push(items.size)
end

def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void
  f.call("#{path} #{timeout_ms}")
end

def show(line: String) -> Void
  puts(line)
end

def countdown(n: Int, step: Int = 1) -> Int
  if n <= 0
    return n
  end
  return countdown(n - step)
end

def main() -> Void
  puts(join(["a", "b"]))
  puts(join(["a", "b"], "-"))
  puts(scale(5))
  puts(scale(5, 3))
  puts(scale(5, 3, 0, 1.5, false))
  puts(describe("x"))
  puts(describe("y", Mode.Fast, ["t"], {"k": 1}))
  puts(grow())
  puts(grow())
  puts(grow([7, 8]))
  each_line("a.txt") do |line|
    puts(line)
  end
  each_line("b.txt", 50, &show)
  each_line("c.txt", &show)
  puts(countdown(3))
  puts(["a", "b", "c"] |> join())
  puts(4 |> scale())
  f = &join
  puts(f.call(["p", "q"], "+"))
  task = Task.spawn(&grow, [4])
  puts(Task.await(task))
end
