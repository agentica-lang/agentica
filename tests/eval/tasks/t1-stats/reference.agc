def main() -> Void
  count = 0
  sum = 0
  largest = 0
  while not IO.eof?()
    n = IO.gets!().strip.to_i!
    if count == 0 or n > largest
      largest = n
    end
    count = count + 1
    sum = sum + n
  end
  puts("count: " + count.to_s)
  puts("sum: " + sum.to_s)
  puts("max: " + largest.to_s)
end
