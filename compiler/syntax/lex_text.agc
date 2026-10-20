import Diag from "../diagnostics/diagnostic"
import Lexer from "lexer"
import Text from "text"
import Tokens from "token"

export def lex_text(text: String) -> String
  case Lexer.lex(text)
    Diag.Outcome.Done(tokens) -> return tokens.map do |token| token_line(token) end.join("\n")
    Diag.Outcome.Failed(problem) -> return Text.diagnostic_line(problem)
  end
end

def value_text(token: Tokens.Token) -> String
  case token.value
    Tokens.Value.NoValue -> return "-"
    Tokens.Value.Text(text) ->
      if text == token.lexeme
        return "="
      end
      return Text.quote(text)
    Tokens.Value.Whole(number) -> return number.to_s
    Tokens.Value.Huge(digits) -> return digits
    Tokens.Value.Real(number) -> return "bits:#{Float.to_bits(number)}"
    Tokens.Value.Doc(block) -> return "doc #{Text.quote(block.text)} #{block.next}"
  end
end

def token_line(token: Tokens.Token) -> String
  return "#{token.kind} #{Text.span_text(token.span)} #{Text.quote(token.lexeme)} #{value_text(token)}"
end
