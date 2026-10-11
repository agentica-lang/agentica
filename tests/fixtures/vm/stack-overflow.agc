def down(n: Int) -> Int
  return down(n + 1) + 1
end

def main() -> Void
  puts("start")
  puts(down(0))
end
