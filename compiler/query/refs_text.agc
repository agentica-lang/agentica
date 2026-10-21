## The text form of `agentica refs` (docs/future/39-semantic-cli.md, 39.2): the definition first, then one line for
## each reference, so the output reads like `rg`. Each line starts with `file:line:column` of the name: `definition
## field User.email: String`, `read in total`, `construct` (at the top level). A builtin has no definition line.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Definitions from "definitions"
import Refs from "refs"

## The lines of `answered`, a line feed after each; `names` gives the name of each file (see refs_json.agc).
export def text(names: Map[String, String], answered: Refs.Answer) -> String
  lines: List[String] = []
  case answered.definition
    Ast.Optional.Present(found) ->
      file = names.get(found.file, found.file)
      lines = lines.push("#{place(file, found.name_span)} definition #{described(found, answered.owner)}")
    Ast.Optional.Absent -> lines = lines
  end
  for found in answered.references
    file = names.get(found.file, found.file)
    lines = lines.push("#{place(file, found.span)} #{found.kind}#{inside(found.function)}")
  end
  if lines.size == 0
    return ""
  end
  return "#{lines.join("\n")}\n"
end

def place(file: String, span: Source.Span) -> String
  return "#{file}:#{span.start.line}:#{span.start.column}"
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
def described(found: Definitions.Definition, owner: String) -> String
  if found.kind == "field" or found.kind == "variant"
    return "#{found.kind} #{owner}.#{found.signature}"
  elsif found.kind == "struct" or found.kind == "enum" or found.kind == "alias" or found.kind == "constant"
    return "#{found.kind} #{found.name}"
  end
  return "#{found.kind} #{found.signature}"
end
