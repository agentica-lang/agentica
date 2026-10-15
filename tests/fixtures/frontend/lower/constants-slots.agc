TOTAL = GREETING + " " + LABEL
GREETING = "hello"
LABEL = "world"
SQUARES = [1, 2, 3].map do |n| n * n end
SUM = SQUARES.reduce(0) do |acc, n| acc + n end
ORIGIN = Point(x: -1, y: SUM)
MOVED = ORIGIN.with(x: 0)
KEYS = Set.new(["if", "end"])
LEVELS: Map[String, Int] = {"debug": 0, "info": 1}
UNUSED = [9, 9]

struct Point
  x: Int
  y: Int
end

def classify(word: String) -> String
  if KEYS.include?(word)
    return "keyword"
  end
  return "word"
end

def main() -> Void
  puts(TOTAL)
  puts("#{SQUARES} #{SUM} #{MOVED} #{LEVELS["info"]}")
  puts(classify("end"))
  xs = [1, 2]
  puts(xs.map do |n| n + SUM end)
end
