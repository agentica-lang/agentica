def main() -> Void
  puts(Random.int(1, 6))
  puts(Random.int(-1000000, 1000000))
  puts(Random.int(0, 4294967086))
  puts(Random.int(0, 4294967087))
  puts(Random.int(-9223372036854775807 - 1, 9223372036854775807))
  puts(Random.int(1, 1000000000000000000))
  puts(Random.int(-9223372036854775807 - 1, -1))
  puts(Random.int(7, 7))
  puts(Random.float())
  puts(Random.float)
  total = 0
  for i in 1..200
    total = total + Random.int(0, i)
  end
  puts(total)
  sum = 0.0
  for _ in 1..100
    sum = sum + Random.float
  end
  puts(sum)
  rolls = [Random.int(1, 6), Random.int(1, 6), Random.int(1, 6)]
  puts(rolls)
end
