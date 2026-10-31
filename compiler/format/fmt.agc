## The stage program of the formatter's tests: `fmt.agc FILE...` prints each file formatted (format.agc),
## `fmt.agc --tree FILE...` its normal form and `fmt.agc --raw FILE...` the output without the formatter's own check,
## each after a `== FILE` line; a file that is refused prints its diagnostic line. Each output ends with a line break.

import Diag from "../diagnostics/diagnostic"
import SourceReader from "../io/source_reader"
import SourceFile from "../syntax/source_file"
import Text from "../syntax/text"
import Format from "format"

def main() -> Void
  args = System.args()
  mode = ""
  paths = args
  if args.size > 0 and (args[0] == "--tree" or args[0] == "--raw")
    mode = args[0]
    paths = args.drop(1)
  end

  for path in paths
    puts("== #{path}")
    case SourceReader.read(path)
      SourceFile.Read.Text(text) -> print(shown(text, mode))
      SourceFile.Read.Invalid(at) -> puts(Text.diagnostic_line(SourceFile.invalid_utf8(at)))
      SourceFile.Read.Unreadable(message) -> puts("!! #{message}")
    end
  end
end

def shown(text: String, mode: String) -> String
  if mode == "--raw"
    case Format.unchecked_text(text, Format.WIDTH)
      Diag.Outcome.Done(output) -> return output
      Diag.Outcome.Failed(problem) -> return Text.diagnostic_line(problem) + "\n"
    end
  end

  if mode == "--tree"
    case Format.tree_text(text)
      Diag.Outcome.Done(output) -> return output + "\n"
      Diag.Outcome.Failed(problem) -> return Text.diagnostic_line(problem) + "\n"
    end
  end

  case Format.format_text(text, Format.WIDTH)
    Diag.Outcome.Done(output) -> return output
    Diag.Outcome.Failed(problem) -> return Text.diagnostic_line(problem) + "\n"
  end
end
