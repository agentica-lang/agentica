def total(xs: List[Int]) -> Int
  sum = 0
  count = 0
  for x in xs
    sum += x
    count += 1
  end
  return sum
end

def main() -> Void
  puts(total([1]))
end
