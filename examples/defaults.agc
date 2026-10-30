# Default parameter values: a call may leave out the trailing parameters that have one.

enum Level
  Info
  Warn
end

# A default is a constant: a literal, true, false, nil, none, [], {} or an enum variant without a payload.
def label(text: String, level: Level = Level.Info, tags: List[String] = []) -> String
  return "#{level} #{text} #{tags.size}"
end

def join(words: List[String], sep: String = ", ") -> String
  return words.join(sep)
end

# A last Fn parameter stays without a default so that a block can fill it.
def each_word(text: String, limit: Int = 2, f: Fn[String, Void]) -> Void
  text.split(" ").take(limit).each do |word|
    f.call(word)
  end
end

def show(word: String) -> Void
  puts("- #{word}")
end

def main() -> Void
  puts(label("start"))
  puts(label("slow", Level.Warn, ["disk"]))
  puts(join(["a", "b", "c"]))
  puts(join(["a", "b", "c"], "-"))
  each_word("one two three") do |word|
    puts(word)
  end
  each_word("one two three", 3, &show)
end
