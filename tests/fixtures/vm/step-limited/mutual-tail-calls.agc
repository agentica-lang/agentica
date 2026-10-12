def ping(n: Int) -> Int
  return pong(n + 1)
end

def pong(n: Int) -> Int
  return ping(n + 1)
end

def main() -> Void
  puts("start")
  puts(ping(0))
  puts("done")
end
