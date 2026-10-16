struct Note
  title: String
  body: String
end

def banner(name: String) -> String
  return <<~TEXT
    == #{name.upcase} ==
      indented by two

    last line
  TEXT
end

def join_two(first: String, second: String) -> String
  return "#{first}+#{second}"
end

def main() -> Void
  print(banner("tool"))
  puts("---")
  n = 7
  note = Note(
    title: "t",
    body: <<~BODY,
      count: #{n * 6}
      list: #{[1, 2].map do |x| x + n end}
      map: #{{"k": n}["k"]} str: #{"a#{n}b"}
      escapes: \t tab, \\ slash, \" quote, \#{not}, "plain"
    BODY
  )
  print(note.body)
  puts("---")
  joined = join_two(<<~LEFT, <<~RIGHT)
    left one
      left two
  LEFT
    right one
    right two
  RIGHT
  print(joined)
  puts("---")
  lines = <<~LINES.split("\n")
    a
    b

    d
  LINES
  puts(lines.size)
  puts(lines.inspect)
  puts(<<~ONE.length)
    ab

  ONE
end
