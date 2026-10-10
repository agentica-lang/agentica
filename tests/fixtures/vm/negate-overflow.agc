def flip(n: Int) -> Int
  return -n
end

def main() -> Void
  puts(flip(5))
  puts(flip(-9223372036854775807 - 1))
end
