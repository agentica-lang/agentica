def spin(n: Int) -> Result[Int]
  while true
    n += 1
  end
  return ok(n)
end

def main() -> Void
  puts(Task.map([1], 1, 600000) do |n| spin(n) end)
end
