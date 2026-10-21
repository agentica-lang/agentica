## The position of a query (docs/future/39-semantic-cli.md, 39.3): the word `FILE:LINE:COL` of the command line, and
## the place it names in the text of FILE. Line and column count from 1, in the units of the spans of the front end
## (the characters of the text); a column is an offset in its line.

import Problems from "../diagnostics/problem"
import QueryOptions from "query_options"
import Source from "../syntax/source"

# The most digits of a line or a column: nine always fit an Int.
MAX_DIGITS = 9

## A position asked for: the file, as typed, and a line and a column, both at least 1.
export struct Asked
  file: String
  line: Int
  column: Int
end

## The position of a word, or why the word is not one.
export enum Parsed
  Ready(Asked)
  Refused(Problems.Problem)
end

## Where a position falls in the text: on a character, with its offset, or outside the text, with the span at the end
## of the line it is past, or at the end of the text when the line does not exist.
export enum Located
  At(Int)
  Outside(Source.Span)
end

## Reads `FILE:LINE:COL`. The last two colons end the file name, so a name that holds colons (`C:\src\a.agc`) works.
## `usage` is the usage line of the command, given as the help of QUERY-USAGE.
export def parse(word: String, usage: String) -> Parsed
  parts = word.split(":")
  if parts.size < 3
    return Parsed.Refused(QueryOptions.refusal("#{word} is not FILE:LINE:COL", usage))
  end
  line = number(parts[parts.size - 2])
  column = number(parts[parts.size - 1])
  file = parts.take(parts.size - 2).join(":")
  if file == "" or line < 1 or column < 1
    return Parsed.Refused(QueryOptions.refusal("#{word} is not FILE:LINE:COL, from line 1 and column 1", usage))
  end
  return Parsed.Ready(Asked(file: file, line: line, column: column))
end

## Where `line` and `column` fall in `text`. A column on the line break, or past it, is outside, at the end of its
## line; a line past the last is outside, at the end of the text.
export def locate(text: String, line: Int, column: Int) -> Located
  lines = text.split("\n")
  if lines.size == 0
    return Located.Outside(point(0, 1, 1))
  end
  start = 0
  at = 1
  while at < line and at <= lines.size
    start += lines[at - 1].length + 1
    at += 1
  end
  if line > lines.size
    return Located.Outside(point(text.length, lines.size, lines[lines.size - 1].length + 1))
  elsif column > lines[line - 1].length
    return Located.Outside(point(start + lines[line - 1].length, line, lines[line - 1].length + 1))
  end
  return Located.At(start + column - 1)
end

## The span of the one character at `line` and `column`, which is at `offset`.
export def character(offset: Int, line: Int, column: Int) -> Source.Span
  here = Source.Position(offset: offset, line: line, column: column)
  return Source.Span(start: here, stop: Source.Position(offset: offset + 1, line: line, column: column + 1))
end

# The empty span at the end of a line.
def point(offset: Int, line: Int, column: Int) -> Source.Span
  here = Source.Position(offset: offset, line: line, column: column)
  return Source.Span(start: here, stop: here)
end

# The value of a run of digits, or 0 for anything else: a position starts at 1, so 0 stands for "not a number".
def number(text: String) -> Int
  if text.length == 0 or text.length > MAX_DIGITS
    return 0
  end
  if !text.split("").all? do |character: String| character.code >= 48 and character.code <= 57 end
    return 0
  end
  return text.to_i!
end
