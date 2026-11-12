def main() -> Void
  words = ["a", "b"].map do |word| word.upcase end.join(", ")
  puts(words)
end
