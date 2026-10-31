import SourceReader from "../io/source_reader"
import SourceFile from "../syntax/source_file"
import Text from "../syntax/text"
import CommentsText from "comments_text"

def main() -> Void
  for path in System.args()
    puts("== #{path}")
    case SourceReader.read(path)
      SourceFile.Read.Text(text) -> puts(CommentsText.attach_text(text))
      SourceFile.Read.Invalid(at) -> puts(Text.diagnostic_line(SourceFile.invalid_utf8(at)))
      SourceFile.Read.Unreadable(message) -> puts("!! #{message}")
    end
  end
end
