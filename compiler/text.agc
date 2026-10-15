## Text helpers shared by the text forms of the lexer and the parser.

import Diag from "diagnostic"
import Source from "source"
import Unicode from "unicode"

## A String as ASCII text between double quotes; every other character is written as \\u{HEX}.
export def quote(text: String) -> String
  codes = text.split("").map do |character| String.code(character) end
  parts: List[String] = ["\""]
  segment = 0
  index = 0
  while index < codes.size
    code = codes[index]
    if code < 32 or code > 126 or code == 34 or code == 92
      parts = parts.push(text.slice(segment, index - segment))
      parts = parts.push(escaped(code))
      segment = index + 1
    end
    index += 1
  end
  parts = parts.push(text.slice(segment, codes.size - segment))
  parts = parts.push("\"")
  return parts.join("")
end

## A span as offset:line:column-offset:line:column.
export def span_text(span: Source.Span) -> String
  return "#{position_text(span.start)}-#{position_text(span.stop)}"
end

## The ERROR line of a diagnostic: code, span, message and help (- when there is none).
export def diagnostic_line(problem: Diag.Diagnostic) -> String
  return "ERROR #{problem.code} #{span_text(problem.span)} #{quote(problem.message)} #{help_text(problem.help)}"
end

def escaped(code: Int) -> String
  case code
    34 -> return "\\\""
    92 -> return "\\\\"
    10 -> return "\\n"
    13 -> return "\\r"
    9 -> return "\\t"
    _ -> return "\\u{#{Unicode.hex_text(code)}}"
  end
end

def position_text(position: Source.Position) -> String
  return "#{position.offset}:#{position.line}:#{position.column}"
end

def help_text(help: Diag.Help) -> String
  case help
    Diag.Help.NoHelp -> return "-"
    Diag.Help.Hint(text) -> return quote(text)
  end
end
