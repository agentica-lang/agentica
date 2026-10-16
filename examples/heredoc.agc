# Heredocs: a string of several lines. The common indentation of the text is removed.

def usage(program: String, version: Int) -> String
  return <<~TEXT
    Usage: #{program} [options] FILE

      --verbose   print more
      --version   print #{version}.0 and stop

    Exit code 0 on success.
  TEXT
end

# The rest of the opener line is code, so a heredoc is a value like any other string, and two on a line take their
# texts one after the other.
def banner(title: String, body: String) -> String
  return "#{title.upcase}\n#{body}"
end

def main() -> Void
  print(usage("tool", 2))
  print(banner("notes", <<~NOTE))
    first line
      indented line
  NOTE
  puts(<<~LEFT.length + <<~RIGHT.length)
    ab
    cd
  LEFT
    xyz
    uvw
  RIGHT
end
