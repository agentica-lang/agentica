def down(n: Int) -> Int
  return down(n + 1) + 1
end

def run() -> Int
  return down(0) + 1
end

def main() -> Void
  puts("start")
  puts(run())
end
