## The driver of the formatter: text in, formatted text or a diagnostic out.
##
## It lexes the text with its comments, parses it, attaches the comments (comments.agc), lays the tree out
## (layout.agc) and prints the document in the width (doc.agc). A file that does not lex or parse is refused with
## that diagnostic. Then it checks its own work: the output must parse to the same normal form as the input,
## with the same words of comments in the same order, or the file is refused with FMT-INTERNAL and nothing is written.
##
## With `blank_line_after_end`, every bare `end` gets the empty line after it that CHECK-BLANK-LINE-AFTER-END asks
## for (check/check_style.agc), the `end` of a one-line `do ... end` that the layout broke included; the end of the
## file gets none.
##
## The normal form (`tree_text`, what `agentica fmt --tree` prints) is the parse text of the tree (parse_text.agc)
## without node ids and spans, which the layout moves, and without the `guard` mark of an `if` and the `expression`
## mark of a one-line `def`, since the layout writes a guard or a one-line def too long for its line as the `if` or
## the `def` with a body that it stands for, and writes a def whose body is one `return value` as a one-line def when
## it fits. The `implicit` mark of a `return` goes too: the last expression of a def and its `return` written out are
## one tree. Then one line with the words of every comment in order, since a long comment is wrapped into more lines.

import Style from "../check/check_style"
import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import ParseText from "../syntax/parse_text"
import Parser from "../syntax/parser"
import Source from "../syntax/source"
import Tokens from "../syntax/token"
import Comments from "comments"
import Docs from "doc"
import Layout from "layout"

## The width of the output when no `[style] max_line_width` sets one (47.9, question 1).
WIDTH = 119

## What the formatter is asked: the width of the output, and whether every bare `end` gets an empty line after it.
struct Settings
  width: Int
  blank_line_after_end: Bool
end

## The settings of a file with no `[style]`: the width WIDTH and no empty line added after `end`.
def default_settings() -> Settings = Settings(width: WIDTH, blank_line_after_end: false)

## The text of `text` formatted as `settings` ask, or the diagnostic of a text that does not lex or parse, or
## FMT-INTERNAL when the output would not keep the tree and the comments. CRLF line ends become LF.
def format_text(text: String, settings: Settings) -> Diag.Outcome[String]
  input = text.replace("\r\n", "\n")
  case parsed(input)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(source) -> checked(normal_form(source), laid_out(input, source, settings))
  end
end

## Like format_text without the check of its own output, which the tests use to show what a refused file would have
## become.
def unchecked_text(text: String, settings: Settings) -> Diag.Outcome[String]
  input = text.replace("\r\n", "\n")
  case parsed(input)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(source) -> Diag.Outcome.Done(laid_out(input, source, settings))
  end
end

## The normal form of `text`, one line per node and a last line with the words of its comments, or the diagnostic of
## a text that does not lex or parse.
def tree_text(text: String) -> Diag.Outcome[String]
  case parsed(text.replace("\r\n", "\n"))
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(source) -> Diag.Outcome.Done(normal_form(source))
  end
end

private

# A text lexed with its comments and parsed.
struct Parsed
  scanned: Lexer.Scanned
  program: Ast.Program
end

def parsed(input: String) -> Diag.Outcome[Parsed]
  case Lexer.lex_with_comments(input)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(scanned) ->
      case Parser.parse(scanned.tokens, 0)
        Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(program) -> Diag.Outcome.Done(Parsed(scanned: scanned, program: program))
      end
  end
end

def laid_out(input: String, source: Parsed, settings: Settings) -> String
  attachment = Comments.attach(source.program, source.scanned.tokens, source.scanned.comments)
  context = Layout.context(input, source.scanned.tokens, attachment, settings.width)
  output = Docs.render(Layout.program_doc(context, source.program), settings.width)
  return with_blank_lines(output) if settings.blank_line_after_end

  output
end

def normal_form(source: Parsed) -> String
  lines = ParseText.print_program_with(source.program, false).map do |line: String| without_marks(line) end
  lines.push(comment_words(source.scanned.comments)).join("\n")
end

# `output` with an empty line after each bare `end` that the style rule asks one for. The output lexes, since the
# layout keeps every token.
def with_blank_lines(output: String) -> String
  case Lexer.lex(output)
    Diag.Outcome.Failed(_) -> output
    Diag.Outcome.Done(tokens) ->
      after = Set.new(Style.missing_lines(output, tokens).map do |token: Tokens.Token| token.span.start.line end)
      return output if after.size == 0

      lines: List[String] = []
      number = 1
      for line in output.split("\n")
        lines = lines.push(line)
        if after.include?(number)
          lines = lines.push("")
        end

        number += 1
      end

      lines.join("\n")
  end
end

# The output, when its normal form is `before`, the input's; else FMT-INTERNAL at the first line where they differ.
def checked(before: String, output: String) -> Diag.Outcome[String]
  case tree_text(output)
    Diag.Outcome.Failed(problem) ->
      at = problem.span.start
      message = "the formatted text does not parse: #{problem.code} at #{at.line}:#{at.column}"
      Diag.Outcome.Failed(internal(message))
    Diag.Outcome.Done(after) ->
      return Diag.Outcome.Done(output) if before == after

      message = "the formatted text changes the tree at: #{first_change(before, after)}"
      Diag.Outcome.Failed(internal(message))
  end
end

def internal(message: String) -> Diag.Diagnostic
  help = Diag.Help.Hint("the file is left as it is; please report it with the file")
  start = Source.position(0, 1, 0)
  Diag.fail("FMT-INTERNAL", message, Source.Span(start: start, stop: start), help)
end

# The first line of `before` that `after` does not have at the same place.
def first_change(before: String, after: String) -> String
  old = before.split("\n")
  new = after.split("\n")
  at = 0
  while at < old.size and at < new.size and old[at] == new[at]
    at += 1
  end

  return old[at].strip if at < old.size

  "the end of the file"
end

# The words of the comments, in order, without their `#` markers.
def comment_words(comments: List[Tokens.Comment]) -> String
  words: List[String] = []
  for comment in comments
    for word in comment.text.split(" ")
      bare = word
      while bare.start_with?("#")
        bare = bare.slice(1, bare.length - 1)
      end

      if bare != ""
        words = words.push(bare)
      end
    end
  end

  "comments: #{words.join(" ")}"
end

# The line without the mark of a form that the layout may turn into another: ` guard` on an `if-stmt` line,
# ` expression` on a `function-decl` line and ` implicit` on a `return-stmt` line (parse_text.agc writes each last on
# its line).
def without_marks(line: String) -> String
  return line.slice(0, line.length - " guard".length) if line.end_with?(" guard") and line.include?("if-stmt ")

  if line.end_with?(" implicit") and line.include?("return-stmt ")
    return line.slice(0, line.length - " implicit".length)
  end

  if line.end_with?(" expression") and line.include?("function-decl ")
    return line.slice(0, line.length - " expression".length)
  end

  line
end
