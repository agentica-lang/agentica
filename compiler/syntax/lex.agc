import SourceReader from "../io/source_reader"
import LexText from "lex_text"
import SourceFile from "source_file"
import Text from "text"

def main() -> Void
  for path in System.args()
    puts("== #{path}")
    case SourceReader.read(path)
      SourceFile.Read.Text(text) -> puts(LexText.lex_text(text))
      SourceFile.Read.Invalid(at) -> puts(Text.diagnostic_line(SourceFile.invalid_utf8(at)))
      SourceFile.Read.Unreadable(message) -> puts("!! #{message}")
    end
  end
end
