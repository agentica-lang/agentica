def spin(n: Int) -> Int
  x = n
  while true
    x = (x + 1) % 1000
  end
  return x
end

def main() -> Void
  puts("start")
  puts(Task.await(Task.spawn(&spin, 1)))
end
