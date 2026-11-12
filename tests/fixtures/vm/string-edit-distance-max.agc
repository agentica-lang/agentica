def main() -> Void
  puts("ab".edit_distance("b", 0))
  puts("ab".edit_distance("b", 0 - 1))
  puts("not reached")
end
