def scale() -> Int
  return 1
end

def main() -> Void
  lines = 200000 * scale()
  i = 0
  while i < lines
    puts("line number #{i % 1000} with some text")
    i += 1
  end
  puts("print-lines #{lines}")
end
