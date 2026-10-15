TABLE = [1, 2, 3]

def never() -> Int
  return TABLE[0]
end

def main() -> Void
  puts("main does not call never")
end
