struct Point
  x: Int
  y: Int = 0
end

# Prints its name, so the order the arguments run in shows.
def side(name: String, value: Int) -> Int
  puts(name)
  value
end

def pair(a: Int, b: Int) -> Int = a * 10 + b

def check(name: String, runs: Int = 100, seed: Int = 7, verbose: Bool = false) -> String
  "#{name} #{runs} #{seed} #{verbose}"
end

def first_or[T](items: List[T], fallback: T) -> T
  return fallback if items.empty?

  items[0]
end

def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void
  f.call("#{path} #{timeout_ms}")
end

def scaled(p: Point, by: Int = 2, shift: Int = 0) -> Point = Point(x: p.x * by + shift, y: p.y * by + shift)

# A tail call with its arguments named in the other order.
def countdown(n: Int, acc: Int = 0) -> Int
  return acc if n == 0

  countdown(acc: acc + n, n: n - 1)
end

def failing() -> Result[Int] = error("boom", kind: "db.constraint", code: 19)

def main() -> Void
  puts(pair(b: side("b", 2), a: side("a", 1)))
  puts(pair(1, b: 2))
  puts(check("sort", verbose: true))
  puts(check("sort", 200, verbose: true))
  puts(check(seed: 3, name: "map"))
  puts(first_or(fallback: "none", items: ["x"]))
  puts(first_or(items: [], fallback: 5))
  each_line("a.txt", timeout_ms: 50) do |line| puts(line) end

  p = Point(x: 1, y: 2)
  puts(scaled(p, shift: 1).inspect)
  puts(scaled(by: 3, p: p.with(y: 5)).inspect)
  puts((p |> scaled(shift: 10)).inspect)
  puts(countdown(n: 4))
  puts(["a", "b"].join(separator: "-"))
  puts([1, 2, 3].each_slice(size: 2).inspect)
  data = "abc abc abc abc".bytes
  puts(Zlib.inflate(Zlib.deflate(data, max_bytes: 4096).unwrap!, max_bytes: 4096).unwrap!.size)
  case failing()
    error(e) -> puts("#{e.kind} #{e.message} #{e.code.unwrap_or(0)}")
    ok(n) -> puts(n)
  end
end
