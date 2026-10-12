def nap(n: Int) -> Void
  Task.sleep(n)
  puts("never")
end

def count(n: Int) -> Void
  total = 0
  for i in 0...n
    total = total + i
  end
  Task.sleep(600000)
  puts("never #{total}")
end

def main() -> Void
  a = Task.spawn(&nap, 600000)
  b = Task.spawn(&count, 50)
  Task.sleep(5)
  puts("main returns")
end
