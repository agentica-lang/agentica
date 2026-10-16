def next(n: Int) -> Int
  return n + 1
end

def even(n: Int) -> Bool
  return n % 2 == 0
end

def add(total: Int, n: Int) -> Int
  return total + n
end

def main() -> Void
  values = Stream.iterate(1, &next).filter(&even).map(&next).take_while do |n|
    n < 8
  end
  puts(values.to_list(10))
  puts(values.reduce(0, &add))
  puts(Stream.iterate(4, &next).take(0).to_list(0))
  puts(Stream.iterate(1, &next).to_list(3))
end
