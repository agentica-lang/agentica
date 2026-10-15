LIMIT = [1, 2].map do |n| n + make() end

def make() -> Int
  return 1
end

def main() -> Void
  puts(LIMIT)
end
