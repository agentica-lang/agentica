## The text form of `agentica symbol` (docs/future/39-semantic-cli.md, 39.2): one line per match, as `outline` prints
## the declaration, so the output reads like `rg`: `file:line:column` first, at the start of the declaration (of the
## name for a field or a variant). A builtin has no place: its lines are `builtin` and the signature of each form.
## Docs are in the JSON form only. The roots that were left out are one line each, `skipped FILE: CODE`, for stderr.

import Builtins from "../catalog/builtins"
import OutlineText from "outline_text"
import Symbol from "symbol"
import SymbolLink from "symbol_link"

## The lines of the matches, each with a line feed at the end.
export def text(matches: List[Symbol.Match]) -> String
  return matches.map do |match: Symbol.Match| match_text(match) end.join("")
end

## One line for each root left out, each with a line feed at the end; empty when none was.
export def skipped_text(skipped: List[SymbolLink.Skipped]) -> String
  lines = skipped.map do |left: SymbolLink.Skipped| "skipped #{left.file}: #{left.problem.code}\n" end
  return lines.join("")
end

def match_text(match: Symbol.Match) -> String
  case match.extra
    Symbol.Extra.Declared ->
      head = OutlineText.declaration_text(match.kind, match.exported, match.signature)
      return "#{OutlineText.place(match.file, match.span)} #{head}\n"
    Symbol.Extra.Field(type) ->
      head = OutlineText.field_text(match.owner, match.name, type)
      return "#{OutlineText.place(match.file, match.name_span)} #{head}\n"
    Symbol.Extra.Variant(_) ->
      head = OutlineText.variant_text(match.owner, match.signature)
      return "#{OutlineText.place(match.file, match.name_span)} #{head}\n"
    Symbol.Extra.Builtin(entry) ->
      return Builtins.signature(entry).split("\n").map do |line: String| "builtin #{line}\n" end.join("")
  end
end
