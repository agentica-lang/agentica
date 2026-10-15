def twice(x: Int, f: Fn[Int, Int]) -> Int
  return f.call(f.call(x))
end


def parse(f: Fn[String, Result[Int]]) -> Result[Int]
  return f.call("4")
end

def main() -> Void
  xs = [3, 1]
  ys: List[String] = xs.map do |x| x.to_s end
  zs: List[Int] = xs.filter do |x| x > 1 end
  total: Int = xs.reduce(0) do |sum, x| sum + x end
  sorted: List[Int] = List.sort_by(xs) do |x| 0 - x end
  xs.each do |x|
    puts(x.to_s)
  end
  a: Bool = xs.any? do |x| x == 1 end
  b: Bool = xs.all? do |x| x > 0 end
  n: Int = twice(1) do |v| v + total end
  labels: List[String] = xs.map do |x: Int|
    if x > 1
      return "big"
    end
    "small"
  end
  r = parse() do |s|
    v = try s.to_i
    ok(v * 2)
  end
  nested = [[1]].map do |row|
    row.map do |v| v + n end
  end
end

