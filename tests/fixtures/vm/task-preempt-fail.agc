def boom(n: Int) -> Int
  return 10 / n
end

def main() -> Void
  t = Task.spawn(&boom, 0)
  _x = 0
  i = 0
  while i < 300
    _x = (_x + 1) % 1000
    i += 1
  end
  puts(Task.unobserved_crash().ok?)
  value = Task.await(t)
  puts("never #{value}")
end
