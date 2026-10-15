## How the linker reports a failure. A Result error is a String, as in the parser, and `try` stops at the first one. The String holds the file the failure is in (a diagnostic has no file of its own in compiler/) and the packed diagnostic.

import Diag from "diagnostic"
import Base from "parse_base"
import Source from "source"

## Where a failure points: the file (a canonical path, or std/... for a standard module) and a span in it.
export struct Site
  file: String
  span: Source.Span
end

## A diagnostic with the file it is in.
export struct Failure
  file: String
  diagnostic: Diag.Diagnostic
end

## The failure for a place in a file.
export def fail_at(site: Site, code: String, message: String, help: Diag.Help) -> String
  return in_file(site.file, Base.bail_span(code, message, site.span, help))
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
  newline = text.index_of("\n").unwrap!
  size = text.slice(0, newline).to_i!
  start = newline + 1 + size
  return Failure(file: text.slice(newline + 1, size), diagnostic: Base.unpack(text.slice(start, text.length - start)))
end

def in_file(file: String, packed: String) -> String
  return file.length.to_s + "\n" + file + packed
end
