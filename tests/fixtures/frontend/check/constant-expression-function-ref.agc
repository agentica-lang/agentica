HANDLER = &make

def make() -> Int
  return 1
end

def main() -> Void
  puts(HANDLER.call())
end
