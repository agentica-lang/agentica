def main() -> Void
  puts("before")
  puts(Task.map([1], 2, 0) do |n| ok(n) end)
  puts("after")
end
