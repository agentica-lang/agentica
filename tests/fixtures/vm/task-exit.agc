def leave(n: Int) -> Int
  puts("leaving")
  System.exit(n)
  return 0
end

def main() -> Void
  t = Task.spawn(&leave, 3)
  Task.sleep(5000)
  puts("never")
end
