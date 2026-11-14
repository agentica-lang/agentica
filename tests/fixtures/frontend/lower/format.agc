def label(name: String, price: Float, n: Int) -> String = format("%-6s|%6.2f|%03d|%x|%s %d%%", name, price, n, n, name, n)

def main() -> Void
  puts(label("ab", 2.5, 7))
end
