def cube(n: Int) -> Result[Int]
  return ok(n * n * n)
end

def total(results: List[Result[Int]]) -> Int
  return results.reduce(0) do |sum, r|
    sum + r.unwrap_or(0)
  end
end

def main() -> Void
  # No item times out, so the number of steps is fixed.
  results = Task.map((1..1000).to_a, 100, 60000, &cube)
  puts(results.size)
  puts(total(results))
  puts(results[999])
end
