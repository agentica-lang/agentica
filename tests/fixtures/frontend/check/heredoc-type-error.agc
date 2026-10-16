def main() -> Void
  text = <<~TEXT
    first
    second #{1 + "x"}
  TEXT
  puts(text)
end
