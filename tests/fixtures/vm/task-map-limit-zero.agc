def main() -> Void
  empty: List[Int] = []
  puts("before")
  puts(Task.map(empty, 0, 1000) do |n| ok(n) end)
  puts("after")
end
