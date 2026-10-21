## The plain text of a problem, as `agentica` prints it on stderr where it
## is, its code and message, the source lines with ^ under the span and - under each label, and the help.
##
## A mark covers `width` characters of one line from `column` (1-based). A span that goes on to another line is marked
## to the end of its first line. The marks of one line are drawn on one row, in the order of their columns, and the
## notes of the labels come under it, the last column first.

import Source from "../syntax/source"
import Diag from "diagnostic"
import Problems from "problem"

struct Mark
  line: Int
  column: Int
  width: Int
  character: String
  note: String
  noted: Bool
end

## The text of the problem. `text` is the text of the file that the problem names. A problem at a key of a manifest or
## a lock has no source lines: the key path takes their place, and a problem about the whole file shows the file name
## alone.
export def format(problem: Problems.Problem, text: String) -> String
  if !Problems.at_source?(problem)
    return without_source(problem)
  end
  lines = text.split("\n")
  marks = [mark(problem.span, "^", "", false, lines)]
  for label in problem.labels
    marks = marks.push(mark(label.span, "-", label.text, true, lines))
  end
  numbers = Set.new(marks.map do |m: Mark| m.line end).to_a.sort
  width = numbers[numbers.size - 1].to_s.length
  body = numbers.map do |number: Int|
    render(number, marks.filter do |m: Mark| m.line == number end, lines, width)
  end
  start = problem.span.start
  head = "#{problem.file}:#{start.line}:#{start.column} error[#{problem.code}]"
  return "#{head}\n#{problem.message}\n\n#{body.join("\n")}#{help_line(problem.help, width)}"
end

## The text of a problem that has no place in the source: the file, the code, the message, and the key when it has one.
export def without_source(problem: Problems.Problem) -> String
  head = "#{problem.file}: error[#{problem.code}]\n#{problem.message}"
  notes: List[String] = []
  if problem.key_path != ""
    notes = notes.push("  = key: #{problem.key_path}")
  end
  notes = notes.concat(help_note(problem.help))
  if notes.size == 0
    return head
  end
  return "#{head}\n\n#{notes.join("\n")}"
end

## The text of a line (1-based), without one carriage return at its end; empty outside the file.
export def line_text(lines: List[String], number: Int) -> String
  if number < 1 or number > lines.size
    return ""
  end
  text = lines[number - 1]
  if text.ends_with?("\r")
    return text.slice(0, text.length - 1)
  end
  return text
end

def help_note(help: Diag.Help) -> List[String]
  case help
    Diag.Help.Hint(text) -> return ["  = help: #{text}"]
    Diag.Help.NoHelp -> return []
  end
end

def help_line(help: Diag.Help, width: Int) -> String
  case help
    Diag.Help.Hint(text) -> return "\n#{spaces(width)} = help: #{text}"
    Diag.Help.NoHelp -> return ""
  end
end

def mark(span: Source.Span, character: String, note: String, noted: Bool, lines: List[String]) -> Mark
  line = span.start.line
  column = span.start.column
  room = line_text(lines, line).length - (column - 1)
  if room < 1
    room = 1
  end
  wanted = room
  if span.stop.line == line
    wanted = span.stop.column - column
  end
  if wanted > room
    wanted = room
  end
  if wanted < 1
    wanted = 1
  end
  return Mark(line: line, column: column, width: wanted, character: character, note: note, noted: noted)
end

def spaces(count: Int) -> String
  return List.repeat(" ", count).join("")
end

# `count` characters of white space under the start of `text`: a tab stays a tab, so marks line up with the source.
def padding(text: String, count: Int) -> String
  characters: List[String] = []
  for index in 0...count
    if index < text.length and text.at(index) == "\t"
      characters = characters.push("\t")
    else
      characters = characters.push(" ")
    end
  end
  return characters.join("")
end

# The source line, its row of marks, and the notes of the labels on it.
def render(number: Int, marks: List[Mark], lines: List[String], gutter: Int) -> String
  text = line_text(lines, number)
  ordered = marks.sort_by do |m: Mark| m.column end
  reach = 0
  for m in ordered
    if m.column - 1 + m.width > reach
      reach = m.column - 1 + m.width
    end
  end
  row = padding(text, reach).split("")
  for m in ordered
    for offset in 0...m.width
      row = row.set(m.column - 1 + offset, m.character)
    end
  end
  number_text = number.to_s
  shown = "#{number_text}#{spaces(gutter - number_text.length)}"
  parts = ["#{shown} | #{text}", "#{spaces(gutter)} | #{row.join("")}"]
  for m in ordered.reverse
    if m.noted
      parts = parts.push("#{spaces(gutter)} | #{padding(text, m.column - 1)}#{m.note}")
    end
  end
  return parts.join("\n")
end
