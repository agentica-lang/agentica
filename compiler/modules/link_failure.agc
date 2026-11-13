## How the linker reports a failure. A Result error is a String, as in the parser, and `try` stops at the first one.
## The String holds the file the failure is in (a diagnostic has no file of its own in compiler/) and the packed
## diagnostic.

import Diag from "../diagnostics/diagnostic"
import Base from "../syntax/parse_base"
import Source from "../syntax/source"

## Where a failure points: the file (a canonical path, or std/... for a standard module) and a span in it.
struct Site
  file: String
  span: Source.Span
end

## A diagnostic with the file it is in. key_path is the place of a failure in a manifest or a lock, which have no
## source span for it (fail_key): the dotted path of the key, "" for any other failure.
struct Failure
  file: String
  key_path: String
  diagnostic: Diag.Diagnostic
end

## The failure for a place in a file.
def fail_at(site: Site, code: String, message: String, help: Diag.Help) -> String
  in_file(site.file, Base.bail_span(code, message, site.span, help))
end

## The failure for the key at key_path in file (agentica.toml or agentica.lock). The span is the start of the file, so
## a consumer that reads one still gets a place; key_path is the real one.
def fail_key(file: String, key_path: String, code: String, message: String, help: Diag.Help) -> String
  start = Source.Position(offset: 0, line: 1, column: 1)
  packed = Base.bail_span(code, message, Source.Span(start: start, stop: start), help)
  "#{file.length}\n#{file}#{key_path.length}\n#{key_path}#{packed}"
end

## The failure for agentica.toml or agentica.lock as a whole: the file is missing or cannot be read, so there is no key
## path and no place in it. The span is empty at line 0, which the text forms read as "no place" (Problems.at_source?),
## so they print the file name and no position.
def fail_file(file: String, code: String, message: String, help: Diag.Help) -> String
  origin = Source.Position(offset: 0, line: 0, column: 0)
  in_file(file, Base.bail_span(code, message, Source.Span(start: origin, stop: origin), help))
end

## The failure for a diagnostic of the lexer or the parser, which have no file.
def from_stage(file: String, problem: Diag.Diagnostic) -> String
  in_file(file, Base.bail_span(problem.code, problem.message, problem.span, problem.help))
end

## A help text.
def hint(text: String) -> Diag.Help = Diag.Help.Hint(text)

## The packed failure `text` with `more` added to its help (after the help it has, if any), for a caller that knows
## what the user should do next.
def add_help(text: String, more: String) -> String
  failure = unpack_failure(text)
  shown = failure.diagnostic
  line = more
  case shown.help
    Diag.Help.Hint(had) -> line = "#{had}; #{more}"
    Diag.Help.NoHelp -> line = more
  end

  packed = Base.bail_span(shown.code, shown.message, shown.span, hint(line))
  "#{failure.file.length}\n#{failure.file}#{failure.key_path.length}\n#{failure.key_path}#{packed}"
end

## Reads back the failure that fail_at or from_stage wrote.
def unpack_failure(text: String) -> Failure
  file = take_field(text, 0)
  key_path = take_field(text, file.next)
  rest = text.slice(key_path.next, text.length - key_path.next)
  Failure(file: file.value, key_path: key_path.value, diagnostic: Base.unpack(rest))
end

private

# A field written as its length, a line feed and its text; next is where the field after it starts.
struct Field
  value: String
  next: Int
end

def take_field(text: String, at: Int) -> Field
  newline = at + text.slice(at, text.length - at).index_of("\n").unwrap!
  size = text.slice(at, newline - at).to_i!
  Field(value: text.slice(newline + 1, size), next: newline + 1 + size)
end

def in_file(file: String, packed: String) -> String = "#{file.length}\n#{file}0\n#{packed}"
