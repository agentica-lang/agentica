enum Mode
  Fast
  Safe
end

def join(xs: List[String], sep: String = ", ") -> String
  return xs.join(sep)
end

def describe(label: String, mode: Mode = Mode.Safe, tags: List[String] = [], meta: Map[String, Int] = {}) -> String
  return "#{label} #{mode} #{tags.size} #{meta.size}"
end

def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void
  f.call(path)
end

def show(line: String) -> Void
  puts(line)
end

def main() -> Void
  puts(join(["a"]))
  puts(join(["a"], "-"))
  puts(describe("x"))
  puts(describe("x", Mode.Fast))
  each_line("a.txt") do |line|
    puts(line)
  end
  each_line("a.txt", 5, &show)
  each_line("a.txt", &show)
  f = &join
  puts(f.call(["a"], ", "))
end
