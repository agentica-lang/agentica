def in_range(low: Int, high: Int, count: Int) -> Int
  inside = 0
  for _ in 1..count
    x = Random.int(low, high)
    if x >= low && x <= high
      inside = inside + 1
    end
  end
  return inside
end

def main() -> Void
  min = -9223372036854775807 - 1
  max = 9223372036854775807
  puts(in_range(1, 6, 50))
  puts(in_range(-1000000, 1000000, 20))
  puts(in_range(0, 4294967087, 20))
  puts(in_range(min, max, 20))
  puts(in_range(min, -1, 20))
  puts(in_range(1, 1000000000000000000, 20))
  puts(Random.int(7, 7))
  puts(Random.int(max, max))
  floats = 0
  for _ in 1..50
    f = Random.float()
    if f >= 0.0 && f < 1.0
      floats = floats + 1
    end
  end
  puts(floats)
  seen = [false, false, false]
  for _ in 1..200
    seen = seen.set(Random.int(0, 2), true)
  end
  puts(seen)
end
