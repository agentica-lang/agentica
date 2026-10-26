## CHECK-BLANK-LINE-AFTER-END: the optional style rule of a project (`[style] blank_line_after_end = true` in
## agentica.toml, docs/grammar/05b-modules.md). A line whose code is only `end` must be followed by an empty line.
##
## The rule reads the tokens of the file, so an `end` inside a string, a heredoc or a comment is never one. The tokens
## say which lines hold code; the text says whether the line after is empty, since a comment line and an empty line
## have no token.

import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Tokens from "../syntax/token"

# The token kinds a line may start with right after an `end`, with no empty line between: the words that go on with the
# block `end` closed (`else`, `elsif`) or close the next one (`end`), and the closing brackets.
FOLLOWERS = Set.new(["end", "else", "elsif", "right-paren", "right-bracket", "right-brace"])

# What the tokens say about one line: how many start on it, and the kind of the leftmost one.
struct Row
  count: Int
  column: Int
  kind: String
end

## The first `end` of `linked` that breaks the rule, among the files whose project asks for it, as a problem at that
## `end` (there is no empty line to point at). The files are taken in program order. Absent when none does.
export def blank_line_after_end(linked: Linker.Linked) -> Ast.Optional[Failure.Problem]
  for module in linked.modules
    if module.blank_line_after_end
      found = in_module(module)
      case found
        Ast.Optional.Present(_) -> return found
        Ast.Optional.Absent -> found = found
      end
    end
  end
  return Ast.Optional.Absent
end

def in_module(module: Linker.LinkedModule) -> Ast.Optional[Failure.Problem]
  case Lexer.lex(module.text)
    Diag.Outcome.Done(tokens) -> return first_missing(module.file, module.text, tokens)
    # A file that linked lexes again, so this arm does not happen.
    Diag.Outcome.Failed(_) -> return Ast.Optional.Absent
  end
end

# The problem at the first bare `end` of the file that is not followed by an empty line.
def first_missing(file: String, text: String, tokens: List[Tokens.Token]) -> Ast.Optional[Failure.Problem]
  rows = rows_of(tokens)
  lines = text.split("\n")
  index = 0
  while index < tokens.size
    token = tokens[index]
    if token.kind == "end" and rows[token.span.start.line].count == 1 and !continued?(tokens, index)
      if needs_empty_line?(lines, rows, token.span.start.line + 1)
        return Ast.Optional.Present(missing(file, token))
      end
    end
    index += 1
  end
  return Ast.Optional.Absent
end

# The rows by line number. A line break and the end of the file hold no code. The tokens of a `#{...}` in a heredoc
# body come after the opener's line in the list, so a row is built from every token, not from its neighbours.
def rows_of(tokens: List[Tokens.Token]) -> Map[Int, Row]
  rows: Map[Int, Row] = {}
  for token in tokens
    if token.kind == "NL" or token.kind == "EOF"
      next
    end
    line = token.span.start.line
    column = token.span.start.column
    if !rows.has_key?(line)
      rows = rows.put(line, Row(count: 1, column: column, kind: token.kind))
    else
      row = rows[line]
      if column < row.column
        row = row.with(column: column, kind: token.kind)
      end
      rows = rows.put(line, row.with(count: row.count + 1))
    end
  end
  return rows
end

# Whether the code after the `end` at `index` goes on with a leading `.name`: the lexer joins that line to the `end`
# (a comment line may sit between), so an empty line there would be a stray dot.
def continued?(tokens: List[Tokens.Token], index: Int) -> Bool
  return index + 1 < tokens.size and tokens[index + 1].kind == "dot"
end

# Whether the line `number` (1-based) must be empty and is not: it exists, it has something on it, and what it starts
# with does not close or go on with the block. The end of the file needs nothing.
def needs_empty_line?(lines: List[String], rows: Map[Int, Row], number: Int) -> Bool
  if number > lines.size or blank?(lines[number - 1])
    return false
  end
  return !(rows.has_key?(number) and FOLLOWERS.include?(rows[number].kind))
end

# Only spaces and tabs (and the carriage return of a CRLF line break).
def blank?(line: String) -> Bool
  return line.split("").all? do |char: String| char == " " or char == "\t" or char == "\r" end
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
