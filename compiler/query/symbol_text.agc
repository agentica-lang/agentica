## The text form of `agentica symbol` (docs/future/39-semantic-cli.md, 39.2): one line per match, as `outline` prints
## the declaration, so the output reads like `rg`: `file:line:column` first, at the start of the declaration (of the
## name for a field or a variant). A builtin has no place: its lines are `builtin` and the signature of each form.
## Docs are in the JSON form only. The roots that were left out are one line each, `skipped FILE: CODE`, for stderr.

import Model from "../analysis/model"
import OutlineText from "outline_text"

## The lines of the matches, each with a line feed at the end.
export def text(found: Model.Symbols) -> String
  return found.matches.map do |match: Model.Symbol| match_text(match) end.join("")
end

## One line for each file left out, each with a line feed at the end; empty when none was.
export def skipped_text(found: Model.Symbols) -> String
  return skipped_lines(found.skipped)
end

## The same lines for any answer that lists `skipped` files (`agentica refs` too).
export def skipped_lines(skipped: List[Model.Skipped]) -> String
  lines = skipped.map do |left: Model.Skipped| "skipped #{left.file}: #{left.diagnostic.code}\n" end
  return lines.join("")
end

def match_text(match: Model.Symbol) -> String
  case match.kind
    "builtin" -> return match.signatures.map do |line: String| "builtin #{line}\n" end.join("")
    "field" ->
      head = OutlineText.field_text(match.owner, match.name, match.type, "")
      return "#{OutlineText.place(match.module, match.name_range)} #{head}\n"
    "variant" ->
      head = OutlineText.variant_text(match.owner, match.signature)
      return "#{OutlineText.place(match.module, match.name_range)} #{head}\n"
    _ ->
      head = OutlineText.declaration_text(match.kind, match.exported, match.signature)
      return "#{OutlineText.place(match.module, match.range)} #{head}\n"
  end
end
