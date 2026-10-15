LIMIT = SIZE * 2
SIZE = 8
GREETING = "hello " + NAME
NAME = "world"
EMPTY: Map[String, Int] = {}
WORDS = ["a", "b"]
LOUD = WORDS.map do |word| word + "!" end
TOTAL = [1, 2, 3].reduce(0) do |sum, n| sum + n end
KEYWORDS = Set.new(WORDS)
LEVELS = {"a": 1, "b": LIMIT}
ORIGIN = Point(x: 0, y: 0)
MOVED = ORIGIN.with(x: LIMIT)
FIRST = Color.Red
SHOWN = FIRST.to_s
RATIO: Float = 1.5

struct Point
  x: Int
  y: Int
end

enum Color
  Red
  Green
end

def main() -> Void
  puts("#{GREETING} #{LIMIT} #{LOUD} #{TOTAL} #{SHOWN} #{RATIO}")
  puts(KEYWORDS.include?("a"))
  puts(LEVELS["b"] + EMPTY.size + MOVED.x)
  WORDS.each do |word|
    puts(word)
  end
end
