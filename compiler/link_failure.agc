## How the linker reports a failure. A Result error is a String, as in the parser, and `try` stops at the first one.
## The String holds the file the failure is in (a diagnostic has no file of its own in compiler/) and the packed
## diagnostic.

import Diag from "diagnostic"
import Base from "parse_base"
import Source from "source"

## Where a failure points: the file (a canonical path, or std/... for a standard module) and a span in it.
export struct Site
  file: String
  span: Source.Span
end

## A diagnostic with the file it is in. key_path is the place of a failure in a manifest or a lock, which have no
## source span for it (fail_key): the dotted path of the key, "" for any other failure.
export struct Failure
  file: String
  key_path: String
  diagnostic: Diag.Diagnostic
end

# A field written as its length, a line feed and its text; next is where the field after it starts.
struct Field
  value: String
  next: Int
end

## The failure for a place in a file.
export def fail_at(site: Site, code: String, message: String, help: Diag.Help) -> String
  return in_file(site.file, Base.bail_span(code, message, site.span, help))
end

## The failure for the key at key_path in file (agentica.toml or agentica.lock). The span is the start of the file, so
## a consumer that reads one still gets a place; key_path is the real one.
export def fail_key(file: String, key_path: String, code: String, message: String, help: Diag.Help) -> String
  start = Source.Position(offset: 0, line: 1, column: 1)
  packed = Base.bail_span(code, message, Source.Span(start: start, stop: start), help)
  return "#{file.length}\n#{file}#{key_path.length}\n#{key_path}#{packed}"
end

## The failure for a diagnostic of the lexer or the parser, which have no file.
export def from_stage(file: String, problem: Diag.Diagnostic) -> String
  return in_file(file, Base.bail_span(problem.code, problem.message, problem.span, problem.help))
end

## A help text.
export def hint(text: String) -> Diag.Help
  return Diag.Help.Hint(text)
end

## Reads back the failure that fail_at or from_stage wrote.
export def unpack_failure(text: String) -> Failure
  file = take_field(text, 0)
  key_path = take_field(text, file.next)
  rest = text.slice(key_path.next, text.length - key_path.next)
  return Failure(file: file.value, key_path: key_path.value, diagnostic: Base.unpack(rest))
end

def take_field(text: String, at: Int) -> Field
  newline = at + text.slice(at, text.length - at).index_of("\n").unwrap!
  size = text.slice(at, newline - at).to_i!
  return Field(value: text.slice(newline + 1, size), next: newline + 1 + size)
end

def in_file(file: String, packed: String) -> String
  return "#{file.length}\n#{file}0\n#{packed}"
end
