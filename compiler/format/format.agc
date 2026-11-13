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
  case unchecked_text(input, settings)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(output) -> checked(input, output)
  end
end

## Like format_text without the check of its own output, which the tests use to show what a refused file would have
## become.
def unchecked_text(text: String, settings: Settings) -> Diag.Outcome[String]
  input = text.replace("\r\n", "\n")
  case Lexer.lex_with_comments(input)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(scanned) ->
      case Parser.parse(scanned.tokens, 0)
        Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(parsed) ->
          program = as_written(parsed)
          attachment = Comments.attach(program, scanned.tokens, scanned.comments)
          context = Layout.context(input, scanned.tokens, attachment, settings.width)
          output = Docs.render(Layout.program_doc(context, program), settings.width)
          return Diag.Outcome.Done(with_blank_lines(output)) if settings.blank_line_after_end

          Diag.Outcome.Done(output)
      end
  end
end

## The normal form of `text`, one line per node and a last line with the words of its comments, or the diagnostic of
## a text that does not lex or parse.
def tree_text(text: String) -> Diag.Outcome[String]
  case Lexer.lex_with_comments(text.replace("\r\n", "\n"))
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(scanned) ->
      case Parser.parse(scanned.tokens, 0)
        Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(program) ->
          lines = ParseText.print_program(program).map do |line: String| without_marks(without_places(line)) end
          Diag.Outcome.Done(lines.push(comment_words(scanned.comments)).join("\n"))
      end
  end
end

private

# The tree as the text wrote it: in a file or module block with `private`, the parser made each declaration above it
# public (Ast.PrivateMark), and the layout must not write the `export` that the text did not have.
def as_written(program: Ast.Program) -> Ast.Program
  program.with(declarations: written_scope(program.declarations, program.private_mark.some?))
end

def written_scope(declarations: List[Ast.Decl], marked: Bool) -> List[Ast.Decl]
  declarations.map do |decl: Ast.Decl| written_decl(decl, marked) end
end

def written_decl(decl: Ast.Decl, marked: Bool) -> Ast.Decl
  case decl
    Ast.Decl.Export(node) ->
      return written_decl(node.declaration, marked) if marked

      Ast.Decl.Export(node.with(declaration: written_decl(node.declaration, false)))
    Ast.Decl.Constant(node) ->
      return Ast.Decl.Constant(node.with(exported: false)) if marked

      decl
    Ast.Decl.Module(node) ->
      Ast.Decl.Module(node.with(declarations: written_scope(node.declarations, node.private_mark.some?)))
    _ -> decl
  end
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

# The output, when its normal form is the input's; else FMT-INTERNAL at the first line where they differ.
def checked(input: String, output: String) -> Diag.Outcome[String]
  case tree_text(input)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(before) ->
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

  kept.join("")
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

def digit?(char: String) -> Bool = char.length == 1 and "0123456789".include?(char)

def word_char?(char: String) -> Bool
  char.length == 1 and "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_".include?(char)
end

# The index after the digits that start at `at` (`at` itself when there are none).
def digits_from(chars: List[String], at: Int) -> Int
  stop = at
  while stop < chars.size and digit?(chars[stop])
    stop += 1
  end

  stop
end

# The index after a span `N:N:N-N:N:N` that starts at `at`, or -1.
def span_end(chars: List[String], at: Int) -> Int
  cursor = at
  for separator in [":", ":", "-", ":", ":", ""]
    stop = digits_from(chars, cursor)
    return -1 if stop == cursor

    cursor = stop
    if separator != ""
      return -1 if cursor >= chars.size or chars[cursor] != separator

      cursor += 1
    end
  end

  cursor
end
