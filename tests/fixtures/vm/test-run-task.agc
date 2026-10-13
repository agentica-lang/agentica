def serve(n: Int) -> Int
  Test.run([])
  return n
end

def main() -> Void
  task = Task.spawn(&serve, 1)
  Task.sleep(0)
  puts(Task.unobserved_crash())
end
