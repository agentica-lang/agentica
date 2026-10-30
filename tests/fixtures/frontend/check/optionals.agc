def first(xs: List[Int]) -> Optional[Int]
  if xs.size == 0
    return none
  end
  return some(xs[0])
end

def main() -> Void
  found = first([4, 5])
  case found
    some(n) -> puts(n)
    none -> puts("none")
  end
  puts(found.unwrap_or(0) + found.map do |n| n * 2 end.unwrap!)
  puts(found == some(4))
end
