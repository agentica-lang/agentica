import Regex from "std/regex"

def scale() -> Int
  return 1
end

def make_log(lines: Int) -> String
  levels = ["INFO", "INFO", "INFO", "WARN", "INFO", "ERROR", "INFO", "DEBUG"]
  users = ["alice", "bob", "carol", "dave", "erin"]
  parts: List[String] = []
  for i in 0...lines
    tail = "ok"
    if i % 97 == 0
      tail = "timeout after 30s"
    end
    stamp = "2026-11-01T12:#{(i / 60) % 60}:#{i % 60}"
    path = "/api/items/#{i % 1000}"
    parts = parts.push("#{stamp} #{levels[i % 8]} user=#{users[i % 5]} id=#{i * 7} path=#{path} #{tail}")
  end
  return parts.join("\n")
end

def main() -> Void
  # About 1 MB of log at scale 1; the class and alternation cases read its first 100,000 characters.
  log = make_log(15000 * scale())
  head = log.slice(0, 100000)
  literal = Regex.compile("timeout").unwrap!
  word = Regex.compile("[a-z]+").unwrap!
  words = Regex.compile("\\b(?:alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|user)\\b").unwrap!
  scan = Regex.compile("(?m)^(\\S+) ERROR user=(\\w+) id=(\\d+)").unwrap!
  redos = Regex.compile("(a+)+$").unwrap!
  literal_count = Regex.find_all(log, literal).size
  word_count = Regex.find_all(head, word).size
  words_count = Regex.find_all(head, words).size
  ids = Regex.find_all(log, scan).reduce(0) do |sum, m| sum + m.groups[3].text.to_i! end
  # 20 letters: a backtracking matcher takes about a million steps here; a longer text would not finish.
  redos_found = Regex.match?(List.repeat("a", 20).join("") + "!", redos)
  puts("regex #{log.length}: #{literal_count} #{word_count} #{words_count} #{ids} #{redos_found}")
end
