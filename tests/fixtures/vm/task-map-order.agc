def pause(ms: Int) -> Result[Int]
  Task.sleep(ms)
  return ok(ms)
end

def label(n: Int) -> Result[String]
  Task.sleep(2)
  if n == 2
    return error("two failed")
  end
  return ok("item #{n}")
end

def main() -> Void
  # The items end in reverse order; the results keep the order of the list.
  puts(Task.map([30, 20, 10], 3, 5000, &pause))
  # An error is the result of its own item and does not stop the others.
  puts(Task.map([1, 2, 3], 3, 5000, &label))
  # A limit above the size of the list starts every item at once; a limit of 1 runs them one by one.
  puts(Task.map([1, 3], 8, 5000) do |n| label(n) end)
  puts(Task.map([3, 1], 1, 5000) do |n| label(n) end)
end
