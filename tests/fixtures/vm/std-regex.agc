## std/regex: the Go rules that the Python peer of tests/test_std_regex.py cannot check, with hand-checked output.

import Regex from "std/regex"

def re(pattern: String) -> Regex.Regex
  # Every pattern here is valid; a bad one would be a bug of this fixture.
  return Regex.compile(pattern).unwrap!
end

def spans(text: String, pattern: String) -> String
  found = Regex.find_all(text, re(pattern)).map do |m| "#{m.start}-#{m.stop}" end
  return found.join(" ")
end

def show_match(text: String, pattern: String) -> Void
  case Regex.match(text, re(pattern))
    ok(m) -> puts("#{pattern}: #{m.text.inspect} at #{m.start}-#{m.stop}, groups #{m.groups.map(&group_text)}")
    error(message) -> puts("#{pattern}: #{message}")
  end
end

def group_text(g: Regex.Group) -> String
  if g.matched
    return "#{g.text}@#{g.start}"
  end
  return "-"
end

def show_compile(pattern: String) -> Void
  case Regex.compile(pattern)
    ok(_) -> puts("#{pattern.inspect}: ok")
    error(message) -> puts("#{pattern.inspect}: #{message}")
  end
end

def show_replace(text: String, pattern: String, template: String) -> Void
  case Regex.replace(text, re(pattern), template)
    ok(out) -> puts("replace #{template.inspect}: #{out.inspect}")
    error(message) -> puts("replace #{template.inspect}: #{message}")
  end
end

def read_year(text: String) -> Result[String]
  found = try Regex.match(text, try Regex.compile("(?P<year>\\d{4})-\\d{2}-\\d{2}"))
  year = try Regex.named(found, "year")
  return ok(year.text)
end

def main() -> Void
  # Leftmost-first, as Go and Python; POSIX would give "ab".
  show_match("ab", "a|ab")
  # $ is the end of the text only, unless (?m); \z always.
  puts(Regex.match?("a\n", re("a$")))
  puts(Regex.match?("a\n", re("(?m)a$")))
  puts(Regex.match?("a\n", re("a\\z")))
  # Named groups in both forms, a group that did not take part, character positions.
  show_match("día 2024-05-06", "(?<y>\\d+)-(?P<m>\\d+)(x)?")
  puts(read_year("on 2024-05-06"))
  puts(Regex.named(Regex.match("ab", re("(?<x>a)")).unwrap!, "nope"))
  # A { that starts no repetition is literal, as in RE2; {,3} too.
  show_match("a{,3}", "a{,3}")
  # A flag in the middle runs to the end of its group; (?-i) turns it off.
  show_match("xAB", "a(?i)b")
  show_match("xaB", "a(?i)b")
  show_match("AbC", "(?i)a(?-i)b(?i)c")
  show_match("x\"y", "\\x{22}")
  # \B matches in the empty text, as in Go (Python finds nothing there).
  puts(spans("", "\\B"))
  # [: starts a POSIX class only when a :] follows; [[:] is a class of [ and :.
  puts(spans("a[:b", "[[:]+"))
  # named checks the index, so a Match built by JSON.decode cannot make it halt.
  forged = JSON.decode("{\"text\":\"a\",\"start\":0,\"stop\":1,\"groups\":[],\"names\":{\"x\":5}}", Regex.Match)
  puts(Regex.named(forged.unwrap!, "x"))
  # Zero-length matches: Go's rule.
  puts(spans("abxd", "x*"))
  show_replace("abxd", "x*", "-")
  puts(Regex.split("axbc", re("x*")))
  puts(Regex.split(",a,,b,", re(",")))
  puts(Regex.split("one,  two;three", re("[,;]\\s*")))
  puts(Regex.split("", re(",")))
  # Templates.
  show_replace("Ada Lovelace", "(\\w+) (\\w+)", "$2, $1")
  show_replace("ab", "(a)(b)", "$1x|${1}x|$$|$0|$2")
  show_replace("ab", "(a)(b)", "$10")
  show_replace("ab", "(?<first>a)", "[${first}]")
  show_replace("ab", "(a)|(b)", "<$2>")
  show_replace("ab", "(a)", "$1$")
  show_replace("ab", "(a)", "$9")
  # Escape round trip.
  text = "1+1=2? (yes) [a-z] {x} ^$ \\ |."
  escaped = Regex.escape(text)
  puts(escaped)
  puts(Regex.match(text, re(escaped)).unwrap!.text == text)
  # Errors and limits.
  show_compile("a(b")
  show_compile("(a)\\1")
  show_compile("(?=x)")
  show_compile("a{1001}")
  show_compile("(?:a{1000}){11}")
  show_compile("\\x{D800}")
  show_compile("\\pL")
  show_compile("a{,3}")
  show_compile("[[:alpha:]]")
end
