def main() -> Nil
  count = 0
  sum = 0
  largest = 0
  while not IO.eof?()
    n = String.to_int!(String.trim(IO.gets()))
    if count == 0 or n > largest
      largest = n
    end
    count = count + 1
    sum = sum + n
  end
  puts("count: " + String.from_int(count))
  puts("sum: " + String.from_int(sum))
  puts("max: " + String.from_int(largest))
end
