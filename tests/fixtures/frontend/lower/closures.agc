def apply(f: Fn[Int, Int], n: Int) -> Int
  return f.call(n)
end

def double(n: Int) -> Int
  return n * 2
end

def run(n: Int, f: Fn[Int, Int]) -> Int
  return f.call(n)
end

def main() -> Void
  offset = 10
  label = "v"
  xs = [1, 2, 3]
  puts(xs.map do |n| n + offset end)
  puts(xs.map do |n| label + n.to_s + offset.to_s end)
  puts(xs.map do |n| xs.map do |m| m + n + offset end end)
  puts(apply(&double, 4))
  puts(run(3) do |n| n + offset end)
  evens = xs.filter do |n| n % 2 == 0 end
  total = xs.reduce(0) do |acc, n| acc + n end
  puts("#{evens} #{total}")
  xs.each do |n|
    puts(n)
  end
  pairs = xs.map do |a| xs.reduce(a) do |acc, b| acc + b + offset end end
  puts(pairs)
end
