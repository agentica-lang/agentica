def leave(n: Int) -> Int
  System.exit(n)
  return 0
end

def main() -> Void
  t = Task.spawn(&leave, 3)
  x = 0
  while true
    x = (x + 1) % 1000
  end
end
