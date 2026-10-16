def square(n: Int) -> Result[Int]
  Task.sleep(5)
  return ok(n * n)
end

def row(n: Int) -> Result[List[Result[Int]]]
  cells = Task.map([n, n + 1, n + 2], 2, 5000, &square)
  return ok(cells)
end

def main() -> Void
  # Each call has its own limit, so the limits multiply.
  puts(Task.map([1, 4], 2, 5000, &row))
end
