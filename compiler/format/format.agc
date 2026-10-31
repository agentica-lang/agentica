## The driver of the formatter (docs/future/47-formatter.md): text in, formatted text or a diagnostic out.
##
## It lexes the text with its comments, parses it, attaches the comments (comments.agc), lays the tree out
## (layout.agc) and prints the document in the width (doc.agc). A file that does not lex or parse is refused with
## that diagnostic. Then it checks its own work: the output must parse to the same normal form as the input (47.7),
## with the same words of comments in the same order, or the file is refused with FMT-INTERNAL and nothing is written.
##
## The normal form (`tree_text`, what `agentica fmt --tree` prints) is the parse text of the tree (parse_text.agc)
## without node ids and spans, which the layout moves, then one line with the words of every comment in order, since
## a long comment is wrapped into more lines.

import Diag from "../diagnostics/diagnostic"
import Lexer from "../syntax/lexer"
import ParseText from "../syntax/parse_text"
import Parser from "../syntax/parser"
import Source from "../syntax/source"
import Tokens from "../syntax/token"
import Comments from "comments"
import Docs from "doc"
import Layout from "layout"

## The width of the output when no `[style] max_line_width` sets one (47.9, question 1).
export WIDTH = 119

## The text of `text` formatted in `width` columns, or the diagnostic of a text that does not lex or parse, or
## FMT-INTERNAL when the output would not keep the tree and the comments. CRLF line ends become LF.
export def format_text(text: String, width: Int) -> Diag.Outcome[String]
  input = text.replace("\r\n", "\n")
  case unchecked_text(input, width)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(output) -> return checked(input, output)
  end
end

## Like format_text without the check of its own output, which the tests use to show what a refused file would have
## become.
export def unchecked_text(text: String, width: Int) -> Diag.Outcome[String]
  input = text.replace("\r\n", "\n")
  case Lexer.lex_with_comments(input)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(scanned) ->
      case Parser.parse(scanned.tokens, 0)
        Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(program) ->
          attachment = Comments.attach(program, scanned.tokens, scanned.comments)
          context = Layout.context(input, scanned.tokens, attachment)
          return Diag.Outcome.Done(Docs.render(Layout.program_doc(context, program), width))
      end
  end
end

## The normal form of `text`, one line per node and a last line with the words of its comments, or the diagnostic of
## a text that does not lex or parse.
export def tree_text(text: String) -> Diag.Outcome[String]
  case Lexer.lex_with_comments(text.replace("\r\n", "\n"))
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(scanned) ->
      case Parser.parse(scanned.tokens, 0)
        Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(program) ->
          lines = ParseText.print_program(program).map do |line: String| without_places(line) end
          return Diag.Outcome.Done(lines.push(comment_words(scanned.comments)).join("\n"))
      end
  end
end

# The output, when its normal form is the input's; else FMT-INTERNAL at the first line where they differ.
def checked(input: String, output: String) -> Diag.Outcome[String]
  case tree_text(input)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(before) ->
      case tree_text(output)
        Diag.Outcome.Failed(problem) ->
          at = problem.span.start
          message = "the formatted text does not parse: #{problem.code} at #{at.line}:#{at.column}"
          return Diag.Outcome.Failed(internal(message))
        Diag.Outcome.Done(after) ->
          if before == after
            return Diag.Outcome.Done(output)
          end

          message = "the formatted text changes the tree at: #{first_change(before, after)}"
          return Diag.Outcome.Failed(internal(message))
      end
  end
end

def internal(message: String) -> Diag.Diagnostic
  help = Diag.Help.Hint("the file is left as it is; please report it with the file")
  start = Source.position(0, 1, 0)
  return Diag.fail("FMT-INTERNAL", message, Source.Span(start: start, stop: start), help)
end

# The first line of `before` that `after` does not have at the same place.
def first_change(before: String, after: String) -> String
  old = before.split("\n")
  new = after.split("\n")
  at = 0
  while at < old.size and at < new.size and old[at] == new[at]
    at += 1
  end

  if at < old.size
    return old[at].strip
  end

  return "the end of the file"
end

# The words of the comments, in order, without their `#` markers.
def comment_words(comments: List[Tokens.Comment]) -> String
  words: List[String] = []
  for comment in comments
    for word in comment.text.split(" ")
      bare = word
      while bare.starts_with?("#")
        bare = bare.slice(1, bare.length - 1)
      end

      if bare != ""
        words = words.push(bare)
      end
    end
  end

  return "comments: #{words.join(" ")}"
end

# A line of the parse text without its node id (` #12`) and its spans (`3:1:4-9:1:10`).
def without_places(line: String) -> String
  chars = line.split("")
  kept: List[String] = []
  at = 0
  while at < chars.size
    char = chars[at]
    starts = at == 0 or not word_char?(chars[at - 1])
    if char == "#" and at > 0 and chars[at - 1] == " " and digits_from(chars, at + 1) > at + 1
      at = digits_from(chars, at + 1)
    elsif starts and digit?(char) and span_end(chars, at) > at
      at = span_end(chars, at)
    else
      kept = kept.push(char)
      at += 1
    end
  end

  return kept.join("")
end

def digit?(char: String) -> Bool
  return char.length == 1 and "0123456789".contains?(char)
end

def word_char?(char: String) -> Bool
  return char.length == 1 and "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_".contains?(char)
end

# The index after the digits that start at `at` (`at` itself when there are none).
def digits_from(chars: List[String], at: Int) -> Int
  stop = at
  while stop < chars.size and digit?(chars[stop])
    stop += 1
  end

  return stop
end

# The index after a span `N:N:N-N:N:N` that starts at `at`, or -1.
def span_end(chars: List[String], at: Int) -> Int
  cursor = at
  for separator in [":", ":", "-", ":", ":", ""]
    stop = digits_from(chars, cursor)
    if stop == cursor
      return -1
    end

    cursor = stop
    if separator != ""
      if cursor >= chars.size or chars[cursor] != separator
        return -1
      end

      cursor += 1
    end
  end

  return cursor
end
