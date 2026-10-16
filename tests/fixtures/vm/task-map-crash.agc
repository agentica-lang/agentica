def divide(n: Int) -> Result[Int]
  return ok(100 / n)
end

def main() -> Void
  # The item that crashes gives an error for its slot; the others go on.
  puts(Task.map([5, 0, 4], 3, 5000) do |n| divide(n) end)
  puts(Task.unobserved_crash().ok?)
end
