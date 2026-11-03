LIMIT = 10
LABEL = "x"
EMPTY: List[Int] = []

struct Options
  retries: Int = LIMIT
  tags: List[Int] = EMPTY
end

def title(name: String = LABEL, count: Int = LIMIT) -> String
  return "#{name} #{count}"
end

def main() -> Void
  puts(title())
  puts(Options().inspect)
end
