def spin(n: Int) -> Int
  while true
    n += 1
  end
  return n
end

def run() -> Int
  return spin(0) + 1
end

def main() -> Void
  puts(run())
end
