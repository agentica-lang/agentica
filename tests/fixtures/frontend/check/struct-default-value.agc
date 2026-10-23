struct Options
  retries: Int = seed()
end

def seed() -> Int
  return 4
end

def main() -> Void
  puts(Options().inspect)
end
