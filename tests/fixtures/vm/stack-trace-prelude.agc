def check(n: Int) -> Bool
  if n == 2
    puts([1, 2, 3].sum / (n - 2))
  end
  return n > 0
end

def main() -> Void
  puts([1, 2, 3].find do |n| check(n) end)
  puts([1, 2, 3].partition do |n| check(n) end)
end
