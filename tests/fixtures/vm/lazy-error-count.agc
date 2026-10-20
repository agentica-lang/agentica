def main() -> Void
  xs = [1, 2, 3]
  puts(xs.lazy.take(2).to_a)
  count = 1 - 2
  puts(xs.lazy.take(count).to_a)
end
