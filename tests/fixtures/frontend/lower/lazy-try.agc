# A try in the block of a Lazy method lowers to try-step; a try in a function stays try.
def parse(text: String) -> Result[Int]
  n = try text.to_i
  return ok(n)
end

def main() -> Void
  words = ["1", "2"]
  puts(words.lazy.map do |word| try parse(word) end.to_a)
end
