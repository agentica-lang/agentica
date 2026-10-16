def slices(numbers: List[Int], size: Int) -> List[List[Int]]
  return numbers.each_slice(size)
end

def main() -> Void
  puts(slices([1, 2, 3], 3))
  puts(slices([1, 2, 3], -1))
end
