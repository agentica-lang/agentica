def ping(n: Int) -> Int
  if n == 0
    return 1 / n
  end
  return pong(n - 1) + 1
end

def pong(n: Int) -> Int
  return ping(n) + 1
end

def main() -> Void
  puts(ping(40))
end
