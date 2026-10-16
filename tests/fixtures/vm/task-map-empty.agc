def main() -> Void
  empty: List[Int] = []
  puts(Task.map(empty, 2, 1000) do |n| ok(n) end)
  puts(Task.map(empty, 1024, 1) do |n| ok(n) end)
end
