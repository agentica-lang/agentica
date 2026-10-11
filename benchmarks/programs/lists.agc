def scale() -> Int
  return 1
end

def main() -> Void
  rounds = 30 * scale()
  total = 0
  round = 0
  while round < rounds
    xs: List[Int] = []
    i = 0
    while i < 1000
      xs = xs.push((i * 7919 + round * 104729) % 10007)
      i += 1
    end
    evens = xs.filter do |x| x % 2 == 0 end
    squares = evens.map do |x| x * x end
    sum = squares.reduce(0) do |acc, x| acc + x end
    sorted = xs.sort
    big = xs.any? do |x| x > 10000 end
    count = 0
    for x in sorted
      if x > sorted[500]
        break
      end
      count += 1
    end
    total = (total + sum + sorted[0] + sorted[sorted.size - 1] + evens.size + count) % 1000000007
    if big
      total += 1
    end
    round += 1
  end
  puts("lists #{rounds}: checksum #{total}")
end
