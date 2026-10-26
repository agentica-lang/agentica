## CHECK-BLANK-LINE-AFTER-END: the optional style rule of a project (`[style] blank_line_after_end = true` in
## agentica.toml, docs/grammar/05b-modules.md). A line whose code is only `end` must be followed by an empty line.
##
## The rule reads the tokens of the file, so an `end` inside a string, a heredoc or a comment is never one. A bare
## `end` is a token with a line break on both sides. The tokens say whether the next line starts with a word that goes
## on or closes a block; the text says whether it is empty, since a comment line and an empty line have no token. Only
## the one line after each `end` is read, so the cost is the lexing of the file.

import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Tokens from "../syntax/token"

# The token kinds a line may start with right after an `end`, with no empty line between: the words that go on with the
# block `end` closed (`else`, `elsif`) or close the next one (`end`), and the closing brackets.
FOLLOWERS = Set.new(["end", "else", "elsif", "right-paren", "right-bracket", "right-brace"])

## The first `end` of `linked` that breaks the rule, among the files whose project asks for it, as a problem at that
## `end` (there is no empty line to point at). The files are taken in program order. Absent when none does. A file of
## `styled`, which an earlier check found to follow the rule in this very text (modules/check_cache.agc), is not lexed.
export def blank_line_after_end(
  linked: Linker.Linked,
  styled: List[String] = [],
) -> Ast.Optional[Failure.Problem]
  skipped = Set.new(styled)
  for module in linked.modules
    if module.blank_line_after_end and !skipped.include?(module.file)
      case problem_in(module.file, module.text)
        Ast.Optional.Present(problem) -> return Ast.Optional.Present(problem)
        Ast.Optional.Absent -> next
      end
    end
  end

  return Ast.Optional.Absent
end

## Whether `text` has no `end` that the rule refuses, whatever the project of the file asks.
export def follows_rule?(file: String, text: String) -> Bool
  case problem_in(file, text)
    Ast.Optional.Present(_) -> return false
    Ast.Optional.Absent -> return true
  end
end

def problem_in(file: String, text: String) -> Ast.Optional[Failure.Problem]
  case Lexer.lex(text)
    Diag.Outcome.Done(tokens) -> return first_missing(file, text, tokens)
    # A file that linked lexes again, so this arm does not happen.
    Diag.Outcome.Failed(_) -> return Ast.Optional.Absent
  end
end

# The problem at the first bare `end` of the file that is not followed by an empty line. An `end` is bare when a line
# break comes before and after it: a trailing comment is no token, and a line that goes on with a leading `.name` has
# no line break after it, so neither makes it less bare. The kind of a token is checked before its neighbours, so the
# many other tokens cost one comparison.
def first_missing(file: String, text: String, tokens: List[Tokens.Token]) -> Ast.Optional[Failure.Problem]
  for index in 1...tokens.size - 1
    token = tokens[index]
    if token.kind == "end" and tokens[index - 1].kind == "NL" and tokens[index + 1].kind == "NL"
      if needs_empty_line?(text, tokens, index + 1)
        return Ast.Optional.Present(missing(file, token))
      end
    end
  end

  return Ast.Optional.Absent
end

# Whether the line after the line break at `tokens[at]` must be empty and is not. The end of the file needs nothing. A
# line of spaces and tabs (and the carriage return of a CRLF line break) is empty. Else the line must start with a
# word of FOLLOWERS: the first token after the line breaks is the leftmost one of the next line that has code, and
# only its own line, not the position in the list (a heredoc body puts the tokens of its `#{...}` after the opener's
# line), says whether that line is the next one.
def needs_empty_line?(text: String, tokens: List[Tokens.Token], at: Int) -> Bool
  position = tokens[at].span.stop.offset
  while position < text.length
    char = text.slice(position, 1)
    if char == "\n"
      return false
    elsif char != " " and char != "\t" and char != "\r"
      return !follower?(tokens, at)
    end

    position += 1
  end

  return false
end

# Whether the first token after the line breaks from `at` is a FOLLOWERS word on the line right after the `end`'s.
def follower?(tokens: List[Tokens.Token], at: Int) -> Bool
  after = at + 1
  while tokens[after].kind == "NL"
    after += 1
  end

  return tokens[after].span.start.line == tokens[at - 1].span.start.line + 1 and FOLLOWERS.include?(tokens[after].kind)
end

def missing(file: String, token: Tokens.Token) -> Failure.Problem
  return Failure.problem(
    file,
    "",
    "CHECK-BLANK-LINE-AFTER-END",
    "this project asks for an empty line after every end",
    token.span,
    Diag.Help.Hint("add an empty line after this end"),
  )
end
