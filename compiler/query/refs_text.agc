## The text form of `agentica refs` (docs/future/39-semantic-cli.md, 39.2): the definition first, then one line for
## each reference, so the output reads like `rg`. Each line starts with `file:line:column` of the name: `definition
## field User.email: String`, `read in total`, `construct` (at the top level). A builtin has no definition line.

import Model from "../analysis/model"
import OutlineText from "outline_text"

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

def inside(function: String) -> String
  if function == ""
    return ""
  end
  return " in #{function}"
end

# `field User.email: String` and `variant Shape.Circle(Float)` through the owner; `function make(name: String) -> User`
# and `parameter user: User` through the signature; the kind and the name for what a signature adds nothing to (a
# struct, an enum, a type alias, a constant).
def described(found: Model.Declaration) -> String
  if found.kind == "field" or found.kind == "variant"
    return "#{found.kind} #{found.owner}.#{found.signature}"
  elsif found.kind == "struct" or found.kind == "enum" or found.kind == "alias" or found.kind == "constant"
    return "#{found.kind} #{found.name}"
  end
  return "#{found.kind} #{found.signature}"
end
