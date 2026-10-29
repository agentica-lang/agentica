def main() -> Void
  data = "abc".bytes
  puts(data.take(1).length)
  puts(data.take(-1).length)
end
