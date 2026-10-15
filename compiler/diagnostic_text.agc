## The two text forms of a diagnostic that the command line prints (`format-diagnostic` and `format-diagnostic-ai` of
## src/diagnostic.rkt); the JSON form is diagnostic_json.agc. vm/diag.c prints the same forms for runtime errors, so a
## change here is a change there.
##
## Both read the text of the file the problem is in, to show its line. A line is cut at "\n" and loses one trailing
## "\r". A column counts characters.

import Problems from "check_failure"
import Diag from "diagnostic"
import Source from "source"

# A caret or a dash under a line: where it starts (the column, from 1), how many characters it covers, the character
# and the note that goes under the line (empty for none; the primary mark has none).
struct Mark
  line: Int
  column: Int
  width: Int
  character: String
  note: String
end

## The default form:
##
##     FILE:LINE:COLUMN error[CODE]
##     MESSAGE
##
##     LINE | the source line
##          | ^^^^ the primary span, and --- under each label
##          = help: the help
##
## `text` is the text of the file of the problem.
export def plain(problem: Problems.Problem, text: String) -> String
  lines = source_lines(text)
  marks = [mark(problem.span, "^", "", lines)]
  for label in problem.labels
    marks = marks.push(mark(label.span, "-", label.text, lines))
  end
  numbers = marks.map do |each: Mark| each.line end.sort
  distinct: List[Int] = []
  for number in numbers
    if distinct.size == 0 or distinct[distinct.size - 1] != number
      distinct = distinct.push(number)
    end
  end
  gutter = distinct[distinct.size - 1].to_s.length
  rows = distinct.map do |number: Int|
    render_line(number, marks.filter do |each: Mark| each.line == number end, lines, gutter)
  end
  help = hint_text(problem.help)
  if help != ""
    help = "\n#{spaces(gutter)} = help: #{help}"
  end
  start = problem.span.start
  place = "#{problem.file}:#{start.line}:#{start.column}"
  return "#{place} error[#{problem.code}]\n#{problem.message}\n\n#{rows.join("\n")}#{help}"
end

## The compact form for an agent: `check failed: 1 error`, then the code, one `name: value` line for each part the
## problem has (message, place, function, source line, callee, expected, actual, labels, help).
export def ai(problem: Problems.Problem, text: String) -> String
  start = problem.span.start
  line = trim(source_line(source_lines(text), start.line))
  out = [
    "check failed: 1 error",
    "",
    "[#{problem.code}]",
    "  message: #{problem.message}",
    "  at: #{problem.file}:#{start.line}:#{start.column}",
  ]
  out = field(out, "in", problem.signature)
  out = out.push("  source: #{line}")
  out = field(out, "callee", problem.callee)
  out = field(out, "expected", problem.expected)
  out = field(out, "actual", problem.actual)
  for label in problem.labels
    out = out.push("  label: #{label.span.start.line}:#{label.span.start.column} #{label.text}")
  end
  out = field(out, "help", hint_text(problem.help))
  return out.join("\n")
end

def hint_text(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(text) -> return text
    Diag.Help.NoHelp -> return ""
  end
end

def field(out: List[String], name: String, value: String) -> List[String]
  if value == ""
    return out
  end
  return out.push("  #{name}: #{value}")
end

def source_lines(text: String) -> List[String]
  return text.split("\n")
end

# The line (from 1), or "" outside the text, without one trailing "\r".
def source_line(lines: List[String], number: Int) -> String
  if number < 1 or number > lines.size
    return ""
  end
  line = lines[number - 1]
  if line.ends_with?("\r")
    return line.slice(0, line.length - 1)
  end
  return line
end

# The mark of a span on its first line. It covers up to the end of the span when that is on the same line, else the
# rest of the line; always at least one character, and never past the end of the line.
def mark(span: Source.Span, character: String, note: String, lines: List[String]) -> Mark
  line = span.start.line
  column = span.start.column
  room = source_line(lines, line).length - (column - 1)
  if room < 1
    room = 1
  end
  wanted = room
  if span.stop.line == line
    wanted = span.stop.column - column
  end
  width = wanted
  if width > room
    width = room
  end
  if width < 1
    width = 1
  end
  return Mark(line: line, column: column, width: width, character: character, note: note)
end

# One source line with its marks: the line, a row with each mark's characters under it (a later mark in the column
# order overwrites an earlier one), then the notes, the rightmost first.
def render_line(number: Int, marks: List[Mark], lines: List[String], gutter: Int) -> String
  text = source_line(lines, number)
  ordered = by_column(marks)
  width = 0
  for each in ordered
    if each.column - 1 + each.width > width
      width = each.column - 1 + each.width
    end
  end
  empty = spaces(gutter)
  shown = number.to_s
  rows = [
    "#{shown}#{spaces(gutter - shown.length)} | #{text}",
    "#{empty} | #{underline(text, ordered, width)}",
  ]
  for each in ordered.reverse
    if each.note != ""
      rows = rows.push("#{empty} | #{blank(text, 0, each.column - 1)}#{each.note}")
    end
  end
  return rows.join("\n")
end

# The marks by column, those of one column in their order (a stable insertion sort: there are only a few).
def by_column(marks: List[Mark]) -> List[Mark]
  ordered: List[Mark] = []
  for each in marks
    at = ordered.size
    while at > 0 and ordered[at - 1].column > each.column
      at -= 1
    end
    ordered = ordered.take(at).push(each).concat(ordered.drop(at))
  end
  return ordered
end

# The row under the line, `width` characters wide: the mark characters where a mark covers, and elsewhere a space for
# each character of the line, or a tab where the line has one (so the marks stay under their characters).
def underline(text: String, ordered: List[Mark], width: Int) -> String
  stops = [0, width]
  for each in ordered
    stops = stops.push(each.column - 1).push(each.column - 1 + each.width)
  end
  stops = stops.sort
  parts: List[String] = []
  index = 1
  while index < stops.size
    from = stops[index - 1]
    to = stops[index]
    if to > from
      parts = parts.push(segment(text, ordered, from, to))
    end
    index += 1
  end
  return parts.join("")
end

# The characters from `from` to `to`, which no mark starts or ends inside: the last mark that covers them, or blank.
def segment(text: String, ordered: List[Mark], from: Int, to: Int) -> String
  covering = ""
  for each in ordered
    if each.column - 1 <= from and to <= each.column - 1 + each.width
      covering = each.character
    end
  end
  if covering == ""
    return blank(text, from, to)
  end
  return List.repeat(covering, to - from).join("")
end

# What the characters from `from` to `to` of the line become under it: a tab stays a tab, every other character, and
# every position past the end of the line, is a space.
def blank(text: String, from: Int, to: Int) -> String
  inside = to
  if inside > text.length
    inside = text.length
  end
  head = ""
  outside_from = from
  if from < inside
    pieces = text.slice(from, inside - from).split("\t")
    head = pieces.map do |piece: String| spaces(piece.length) end.join("\t")
    outside_from = inside
  end
  return "#{head}#{spaces(to - outside_from)}"
end

def spaces(count: Int) -> String
  if count < 1
    return ""
  end
  return List.repeat(" ", count).join("")
end

# Without the whitespace around it (space, tab, line feed, vertical tab, form feed and carriage return), as Racket's
# string-trim does.
def trim(text: String) -> String
  characters = text.split("")
  first = 0
  last = characters.size
  while first < last and space?(characters[first])
    first += 1
  end
  while last > first and space?(characters[last - 1])
    last -= 1
  end
  return text.slice(first, last - first)
end

def space?(character: String) -> Bool
  code = String.code(character)
  return code == 32 or (code >= 9 and code <= 13)
end
