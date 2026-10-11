def main() -> Void
  xs = ["a", "b"]
  puts(List.drop(xs, 0))
  puts(List.drop(xs, -9223372036854775807 - 1))
end
