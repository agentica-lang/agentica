def boom(n: Int) -> Int
  return 10 / n
end

def main() -> Void
  t = Task.spawn(&boom, 0)
  x = 0
  while true
    x = (x + 1) % 1000
  end
end
