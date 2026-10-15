LEVELS = {"a": 1, "b": 2}
KEYWORDS = Set.new(["a", "b"])
DEFAULT = Color.Red
SHOWN = DEFAULT.to_s
CONFIG = Config(port: 80)

enum Color
  Red
  Green
end

struct Config
  port: Int
end

def main() -> Void
  LEVELS.size
  LEVELS.get("a", 0)
  KEYWORDS.include?("a")
  KEYWORDS.each do |word|
    puts(word)
  end
  KEYWORDS.map do |word| word end
  KEYWORDS.to_a()
  CONFIG.port
  CONFIG.port()
  n = LEVELS["a"]
  m = "a" |> LEVELS.get(0)
  puts("#{KEYWORDS} #{n} #{SHOWN}")
  puts(LEVELS)
  c = CONFIG.with(port: 81)
end
