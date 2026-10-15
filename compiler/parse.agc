import "parse_text" as ParseText

# An argument `--first-id=N` sets the first node id of the files after it (the default is 0).
def main() -> Void
  first_id = 0
  for path in System.args()
    if path.starts_with?("--first-id=")
      first_id = path.slice(11, path.length - 11).to_i!
      next
    end
    puts("== " + path)
    read = File.read_text(path, 10000)
    if read.ok?
      puts(ParseText.parse_text_from(read.unwrap!, first_id))
    else
      puts("!! " + read.message)
    end
  end
end
