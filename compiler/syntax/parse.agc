import SourceReader from "../io/source_reader"
import ParseText from "parse_text"
import SourceFile from "source_file"
import Text from "text"

# An argument `--first-id=N` sets the first node id of the files after it (the default is 0). The argument
# `--continue` numbers each file from the next free id of the one before it (Ast.next_free_id).
def main() -> Void
  first_id = 0
  continuing = false
  for path in System.args()
    if path.starts_with?("--first-id=")
      first_id = path.slice(11, path.length - 11).to_i!
      next
    end
    if path == "--continue"
      continuing = true
      next
    end
    puts("== #{path}")
    case SourceReader.read(path)
      SourceFile.Read.Text(text) ->
        printed = ParseText.print_from(text, first_id)
        puts(printed.text)
        if continuing
          first_id = printed.next_id
        end
      SourceFile.Read.Invalid(at) -> puts(Text.diagnostic_line(SourceFile.invalid_utf8(at)))
      SourceFile.Read.Unreadable(message) -> puts("!! #{message}")
    end
  end
end
