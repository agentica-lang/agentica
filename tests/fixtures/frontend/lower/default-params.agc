enum Mode
  Fast
  Safe
end

def scale(n: Int, factor: Int = 2, ratio: Float = -0.5, on: Bool = true, name: String = "n") -> String
  return "#{n * factor} #{ratio} #{on} #{name}"
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
  puts(scale(1))
  puts(scale(1, 3))
  puts(describe("x"))
  each_line("a.txt") do |line|
    puts(line)
  end
  each_line("a.txt", 5, &show)
end
