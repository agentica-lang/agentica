import Limits from "lib/limits"
import {TOP as LIMIT, NAMES, WINDOW} from "lib/limits"

# Read before the constants it depends on are declared.
TOTAL = GREETING + " " + LABEL
GREETING = "hello"
LABEL = "world"
SIZE = 8
OFFSET = -3
RATIO = 2.5
ENABLED = true
NOTHING = nil
LEVELS = {"debug": 0, "info": 1, "warn": SIZE}
KEYWORDS = Set.new(["if", "else", "end"])
SQUARES = [1, 2, 3, 4].map do |n| n * n end
SUM = SQUARES.reduce(0) do |acc, n| acc + n end
ORIGIN = Point(x: OFFSET, y: SIZE)
MOVED = ORIGIN.with(x: 0)
DEFAULT = Color.Green

struct Point
  x: Int
  y: Int
end

enum Color
  Red
  Green
end

def classify(word: String) -> String
  if KEYWORDS.include?(word)
    return "keyword"
  end
  return "word"
end

def main() -> Void
  puts(TOTAL)
  puts("#{SIZE} #{OFFSET} #{RATIO} #{ENABLED} #{NOTHING}")
  puts(LEVELS.get("warn", -1))
  puts(LEVELS["info"])
  puts(classify("end") + " " + classify("beam"))
  puts("#{SQUARES} #{SUM}")
  puts("#{ORIGIN} #{MOVED} #{DEFAULT}")
  puts("#{LIMIT} #{Limits.top()} #{NAMES} #{WINDOW}")
  NAMES.each do |name|
    puts(name + LABEL)
  end
  puts(KEYWORDS.size)
end
