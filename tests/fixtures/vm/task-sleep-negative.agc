def nap(n: Int) -> Void
  Task.sleep(n)
end

def main() -> Void
  puts("before")
  Task.await(Task.spawn(&nap, -1))
end
