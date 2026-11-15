## A diagnostic as the String of a Result error, which the parser and the linker pass through `try`.

import Source from "../syntax/source"
import Diag from "diagnostic"

## The packed form: the code, the six numbers of the span, a help flag, the length of the message, then the message
## followed by the help.
def pack(code: String, message: String, span: Source.Span, help: Diag.Help) -> String
  numbers = [span.start.offset, span.start.line, span.start.column, span.stop.offset, span.stop.line, span.stop.column]
  fields = numbers.map do |number| number.to_s end
  rest = message
  flag = "0"
  case help
    Diag.Help.Hint(text) ->
      rest = message + text
      flag = "1"
    Diag.Help.NoHelp -> flag = "0"
  end

  "#{code}\n#{fields.join("\n")}\n#{flag}\n#{message.length}\n#{rest}"
end

## Reads back the failure that pack wrote.
def unpack(text: String) -> Diag.Diagnostic
  parts = text.split("\n")
  consumed = 0
  index = 0
  while index < 9
    consumed += parts[index].length + 1
    index += 1
  end

  body = text.slice(consumed, text.length - consumed)
  size = parts[8].to_i!
  help = Diag.Help.NoHelp
  if parts[7] == "1"
    help = Diag.Help.Hint(body.slice(size, body.length - size))
  end

  start = Source.Position(offset: parts[1].to_i!, line: parts[2].to_i!, column: parts[3].to_i!)
  stop = Source.Position(offset: parts[4].to_i!, line: parts[5].to_i!, column: parts[6].to_i!)
  Diag.fail(parts[0], body.slice(0, size), Source.Span(start: start, stop: stop), help)
end
