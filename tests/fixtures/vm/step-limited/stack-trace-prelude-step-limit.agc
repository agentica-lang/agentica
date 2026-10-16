def distinct(count: Int) -> Int
  numbers = List.repeat(7, count)
  return numbers.uniq.size
end

def main() -> Void
  puts(distinct(1000000))
end
