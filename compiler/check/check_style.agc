## The optional style rules of a project, from `[style]` in agentica.toml (docs/grammar/05b-modules.md):
##
## - CHECK-LINE-TOO-LONG (`max_line_width = N`): no line has more than N characters (Unicode code points), comments
##   and doc comments included. A CR before a line feed is not counted.
## - CHECK-BLANK-LINE-AFTER-END (`blank_line_after_end = true`): a line whose code is only `end` must be followed by an
##   empty line. `agentica fmt` adds those lines with `missing_lines` (format/format.agc).
##
## The blank line rule reads the tokens of the file, so an `end` inside a string, a heredoc or a comment is never one.
## A bare `end` is a token with a line break on both sides. The tokens say whether the next line starts with a word
## that goes on or closes a block; the text says whether it is empty, since a comment line and an empty line have no
## token. Only the one line after each `end` is read, so the cost is the lexing of the file.

import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Source from "../syntax/source"
import Tokens from "../syntax/token"

# The token kinds a line may start with right after an `end`, with no empty line between: the words that go on with the
# block `end` closed (`else`, `elsif`) or close the next one (`end`), and the closing brackets.
FOLLOWERS = Set.new(["end", "else", "elsif", "right-paren", "right-bracket", "right-brace"])

## The first style problem of `linked`, among the files whose project asks for a rule, in program order: in each file
## a line that is too long, else an `end` with no empty line after it (a problem at that `end`, since there is no empty
## line to point at). `none` when every file follows its rules. A file of `styled`, which an earlier check found to
## follow the blank line rule in this very text (modules/check_cache.agc), is not lexed.
export def first_problem(linked: Linker.Linked, styled: Set[String]) -> Optional[Failure.Problem]
  for module in linked.modules
    if module.max_line_width > 0
      wide = line_too_long(module.file, module.text, module.max_line_width)
      if !wide.none?
        return wide
      end
    end

    if module.blank_line_after_end and !styled.include?(module.file)
      case problem_in(module.file, module.text)
        some(problem) -> return some(problem)
        none -> next
      end
    end
  end

  return none
end

## The first line of `text` longer than `width` characters, as CHECK-LINE-TOO-LONG from its first character past the
## width to its end. `none` when every line fits.
export def line_too_long(file: String, text: String, width: Int) -> Optional[Failure.Problem]
  offset = 0
  number = 1
  for line in text.split("\n")
    shown = line
    if shown.ends_with?("\r")
      shown = shown.slice(0, shown.length - 1)
    end

    if shown.length > width
      start = Source.position(offset + width, number, offset)
      stop = Source.position(offset + shown.length, number, offset)
      message = "this line has #{shown.length} characters, more than the #{width} of max_line_width"
      help = Diag.Help.Hint("break the line, or shorten a name or a string; agentica fmt breaks what it can")
      span = Source.Span(start: start, stop: stop)
      return some(Failure.problem(file, "", "CHECK-LINE-TOO-LONG", message, span, help))
    end

    offset += line.length + 1
    number += 1
  end

  return none
end

## The bare `end` tokens of `text`, lexed into `tokens`, that have no empty line after them, in order. An `end` is bare
## when a line break comes before and after it: a trailing comment is no token, and a line that goes on with a leading
## `.name` has no line break after it, so neither makes it less bare.
export def missing_lines(text: String, tokens: List[Tokens.Token]) -> List[Tokens.Token]
  found: List[Tokens.Token] = []
  for index in 1...(tokens.size - 1)
    token = tokens[index]
    if token.kind == "end" and tokens[index - 1].kind == "NL" and tokens[index + 1].kind == "NL"
      if needs_empty_line?(text, tokens, index + 1)
        found = found.push(token)
      end
    end
  end

  return found
end

## Whether `text` has no `end` that the rule refuses, whatever the project of the file asks.
export def follows_rule?(file: String, text: String) -> Bool
  return problem_in(file, text).none?
end

def problem_in(file: String, text: String) -> Optional[Failure.Problem]
  case Lexer.lex(text)
    Diag.Outcome.Done(tokens) ->
      missing_ends = missing_lines(text, tokens)
      if missing_ends.size == 0
        return none
      end

      return some(missing(file, missing_ends[0]))
    # A file that linked lexes again, so this arm does not happen.
    Diag.Outcome.Failed(_) -> return none
  end
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
