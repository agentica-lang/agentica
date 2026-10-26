## The text form of `agentica refs` (docs/future/39-semantic-cli.md, 39.2): the definition first, then one line for
## each reference, so the output reads like `rg`. Each line starts with `file:line:column` of the name: `definition
## field User.email: String`, `read in total`, `construct` (at the top level). A builtin has no definition line. The
## roots that were left out are one line each, `skipped FILE: CODE`, for stderr (symbol_text.agc).

import Model from "../analysis/model"
import OutlineText from "outline_text"
import SymbolText from "symbol_text"

## The lines of the answer, a line feed after each.
export def text(found: Model.Refs) -> String
  lines: List[String] = []
  for declared in found.definition
    lines = lines.push("#{OutlineText.place(declared.module, declared.name_range)} definition #{described(declared)}")
  end

  for use in found.references
    lines = lines.push("#{OutlineText.place(use.file, use.range)} #{use.kind}#{inside(use.function)}")
  end

  if lines.size == 0
    return ""
  end

  return "#{lines.join("\n")}\n"
end

## One line for each file left out, each with a line feed at the end; empty when none was.
export def skipped_text(found: Model.Refs) -> String
  return SymbolText.skipped_lines(found.skipped)
end

def inside(function: String) -> String
  if function == ""
    return ""
  end

  return " in #{function}"
end

# `field User.email: String` and `variant Shape.Circle(Float)` through the owner; `function make(name: String) -> User`
# and `parameter user: User` through the signature; the kind and the name for what a signature adds nothing to (a
# struct, an enum, a type alias, a resource, a constant).
def described(found: Model.Symbol) -> String
  if found.kind == "field" or found.kind == "variant"
    return "#{found.kind} #{found.owner}.#{found.signature}"
  elsif ["struct", "enum", "alias", "resource", "constant"].any? do |kind: String| kind == found.kind end
    return "#{found.kind} #{found.name}"
  end

  return "#{found.kind} #{found.signature}"
end
