def main() -> Void
  print("buffered")
  IO.warn("to stderr")
  System.exit(3)
  puts("not reached")
end
