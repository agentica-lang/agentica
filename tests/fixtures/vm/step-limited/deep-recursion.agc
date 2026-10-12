def down(n: Int) -> Int
  return 1 + down(n + 1)
end

def main() -> Void
  puts("start")
  puts(down(0))
  puts("done")
end
