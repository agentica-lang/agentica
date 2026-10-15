import LexText from "lex_text"

def main() -> Void
  for path in System.args()
    puts("== #{path}")
    read = File.read_text(path, 10000)
    if read.ok?
      puts(LexText.lex_text(read.unwrap!))
    else
      puts("!! #{read.message}")
    end
  end
end
