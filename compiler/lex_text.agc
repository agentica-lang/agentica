import "diagnostic" as Diag
import "lexer" as Lexer
import "source" as Source
import "token" as Tokens
import "unicode" as Unicode

export def lex_text(text: String) -> String
  case Lexer.lex(text)
    Diag.Outcome.Done(tokens) -> return tokens.map do |token| token_line(token) end.join("\n")
    Diag.Outcome.Failed(problem) -> return diagnostic_line(problem)
  end
end

def escaped(code: Int) -> String
  case code
    34 -> return "\\\""
    92 -> return "\\\\"
    10 -> return "\\n"
    13 -> return "\\r"
    9 -> return "\\t"
    _ -> return "\\u{" + Unicode.hex_text(code) + "}"
  end
end

def quote(text: String) -> String
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

def position_text(position: Source.Position) -> String
  return "#{position.offset}:#{position.line}:#{position.column}"
end

def span_text(span: Source.Span) -> String
  return position_text(span.start) + "-" + position_text(span.stop)
end

def value_text(token: Tokens.Token) -> String
  case token.value
    Tokens.Value.NoValue -> return "-"
    Tokens.Value.Text(text) ->
      if text == token.lexeme
        return "="
      end
      return quote(text)
    Tokens.Value.Whole(number) -> return number.to_s
    Tokens.Value.Huge(digits) -> return digits
    Tokens.Value.Real(number) -> return "bits:" + Float.to_bits(number).to_s
    Tokens.Value.Doc(block) -> return "doc " + quote(block.text) + " " + block.next
  end
end

def token_line(token: Tokens.Token) -> String
  return token.kind + " " + span_text(token.span) + " " + quote(token.lexeme) + " " + value_text(token)
end

def help_text(help: Diag.Help) -> String
  case help
    Diag.Help.NoHelp -> return "-"
    Diag.Help.Hint(text) -> return quote(text)
  end
end

def diagnostic_line(problem: Diag.Diagnostic) -> String
  return "ERROR " + problem.code + " " + span_text(problem.span) + " " + quote(problem.message) + " " + help_text(problem.help)
end
