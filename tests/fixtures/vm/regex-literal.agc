# A regex literal is Regex.compile of its body, with the flags i and m written as (?i) and (?s) before it. A literal in
# a function body is compiled once, however often the body runs; a literal in a constant is built with the constant.
import Regex from "std/regex"

WORD = /[a-z]+/i
PAIRS = [/(\w+)=(\d+)/, /^a.c$/m]

def same(text: String, literal: Regex.Regex, pattern: String) -> Bool
  built = Regex.compile(pattern).unwrap!
  found = Regex.find_all(text, literal).map do |m: Regex.Match| "#{m.start}-#{m.stop}" end
  wanted = Regex.find_all(text, built).map do |m: Regex.Match| "#{m.start}-#{m.stop}" end
  return literal.source == built.source and found.join(",") == wanted.join(",")
end

def slashes(lines: List[String]) -> Int
  count = 0
  for line in lines
    if Regex.match?(line, /a\/b/)
      count += 1
    end
  end

  return count
end

def main() -> Void
  puts(same("Hello World", WORD, "(?i)[a-z]+"))
  puts(same("x=1 y=22", PAIRS[0], "(\\w+)=(\\d+)"))
  puts(same("a\nc", PAIRS[1], "(?s)^a.c$"))
  puts(same("AxB axb", /a.b/im, "(?is)a.b"))
  puts(same("1.5 and 20", /\d+\.\d+/, "\\d+\\.\\d+"))
  puts(Regex.match?("a\nb", /a.b/))
  puts(Regex.match?("a\nb", /a.b/m))
  puts(slashes(["a/b", "ab", "xa/by", "a\\b"]))
  puts(Regex.replace("2026-11-01", /(\d+)-(\d+)-(\d+)/, "$3/$2/$1").unwrap!)
  puts(/x+/i.source)
  puts(12 / 3 / 2)
end
