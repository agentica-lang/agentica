## The text form of `agentica outline` (docs/future/39-semantic-cli.md, 39.2): one line per declaration, so the
## output reads like `rg`: `file:line:column` first, then the declaration as it is written in the source. A struct's
## fields and an enum's variants follow their declaration, each at the position of its name. Docs are in the JSON form
## only.

import Model from "../analysis/model"
import Signature from "../docs/signature"
import DiagnosticModel from "../diagnostics/diagnostic_model"

## The text of the outline, one line each and a line feed at the end of every line; empty for an empty file.
export def text(outlined: Model.Outline) -> String
  file = outlined.file
  lines: List[String] = []
  for declaration in outlined.imports
    lines = lines.push("#{place(file, declaration.range)} #{import_text(declaration)}")
  end
  for item in outlined.items
    lines = lines.push("#{place(file, item.range)} #{item_text(item)}")
    lines = lines.concat(member_lines(file, item))
  end
  if lines.size == 0
    return ""
  end
  return "#{lines.join("\n")}\n"
end

def place(file: String, range: DiagnosticModel.Region) -> String
  return "#{file}:#{range.start.line}:#{range.start.column}"
end

# `import Models from "models"` or `import {A, B as C} from "models"`.
def import_text(declaration: Model.Import) -> String
  if declaration.alias != ""
    return "import #{declaration.alias} from \"#{declaration.path}\""
  end
  names = declaration.names.map do |name: Model.ImportName| imported_name(name) end
  return "import {#{names.join(", ")}} from \"#{declaration.path}\""
end

def imported_name(name: Model.ImportName) -> String
  if name.local == name.name
    return name.name
  end
  return "#{name.name} as #{name.local}"
end

# The declaration with `export` when it has one; a function with `def`, since its signature does not hold it.
def item_text(item: Model.Item) -> String
  head = item.signature
  if item.kind == "function"
    head = "def #{head}"
  end
  if item.exported
    return "export #{head}"
  end
  return head
end

# `field Struct.name: Type` and `variant Enum.Name(Payload)`, one line each, at the position of the name.
def member_lines(file: String, item: Model.Item) -> List[String]
  fields = item.fields.map do |field: Model.Field|
    "#{place(file, field.name_range)} field #{item.name}.#{field.name}: #{field.type}"
  end
  variants = item.variants.map do |variant: Model.Variant| variant_line(file, item.name, variant) end
  return fields.concat(variants)
end

def variant_line(file: String, enum_name: String, variant: Model.Variant) -> String
  written = Signature.variant_text(variant.name, variant.payload)
  return "#{place(file, variant.name_range)} variant #{enum_name}.#{written}"
end
