VALUE = twice(2) do |n| n end

def twice(x: Int, f: Fn[Int, Int]) -> Int
  return f.call(f.call(x))
end

def main() -> Void
  puts(VALUE)
end
