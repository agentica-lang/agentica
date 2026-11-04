def leave(n: Int) -> Int
  System.exit(n)
  return 0
end

def main() -> Void
  _t = Task.spawn(&leave, 3)
  _x = 0
  while true
    _x = (_x + 1) % 1000
  end
end
