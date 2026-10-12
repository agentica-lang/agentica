def nap(n: Int) -> Void
  Task.sleep(n)
  puts("never")
end

def spin(n: Int) -> Void
  while true
    Task.sleep(0)
  end
end

def main() -> Void
  a = Task.spawn(&nap, 600000)
  b = Task.spawn(&spin, 0)
  Task.sleep(5)
  puts("main returns")
end
