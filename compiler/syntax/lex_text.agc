## The text form of the lexer output, one token per line.

import Diag from "../diagnostics/diagnostic"
import Lexer from "lexer"
import Text from "text"
import Tokens from "token"

## Returns the tokens of the text, one per line, or the line of the first lexing problem.
def lex_text(text: String) -> String
  case Lexer.lex(text)
    Diag.Outcome.Done(tokens) -> tokens.map(&token_line).join("\n")
    Diag.Outcome.Failed(problem) -> Text.diagnostic_line(problem)
  end
end

private

def value_text(token: Tokens.Token) -> String
  case token.value
    Tokens.Value.NoValue -> "-"
    Tokens.Value.Text(text) ->
      return "=" if text == token.lexeme

      Text.quote(text)
    Tokens.Value.Whole(number) -> number.to_s
    Tokens.Value.Huge(digits) -> digits
    Tokens.Value.Real(number) -> "bits:#{Float.to_bits(number)}"
    Tokens.Value.Doc(block) -> "doc #{Text.quote(block.text)} #{block.next}"
    Tokens.Value.Eag(body) -> "eag #{body.indent} #{body.lines.size}"
  end
end

def token_line(token: Tokens.Token) -> String
  "#{token.kind} #{Text.span_text(token.span)} #{Text.quote(token.lexeme)} #{value_text(token)}"
end
