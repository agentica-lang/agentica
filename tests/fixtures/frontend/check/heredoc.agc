def label(name: String, count: Int) -> String
  return <<~TEXT
    name: #{name}
    count: #{count + 1}
  TEXT
end

def main() -> Void
  puts(label("a", 1))
  puts(<<~PLAIN.length)
    one
    two
  PLAIN
end
