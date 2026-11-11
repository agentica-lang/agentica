## The text form of `agentica outline` (docs/future/39-semantic-cli.md, 39.2): one line per declaration, so the
## output reads like `rg`: `file:line:column` first, then the declaration as it is written in the source. A struct's
## fields and an enum's variants follow their declaration, each at the position of its name. Docs are in the JSON form
## only.

import Model from "../analysis/model"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Signature from "../docs/signature"

## The text of the outline, one line each and a line feed at the end of every line; empty for an empty file.
export def text(outlined: Model.Outline) -> String
  file = outlined.file
  lines: List[String] = []
  for declaration in outlined.imports
    lines = lines.push("#{place(file, declaration.range)} #{import_text(declaration)}")
  end

  for item in outlined.items
    lines = lines.concat(item_lines(file, item))
  end

  return "" if lines.size == 0

  "#{lines.join("\n")}\n"
end

## `file:line:column`, the start of `range`, which `rg` prints in front of a hit.
export def place(file: String, range: DiagnosticModel.Region) -> String
  "#{file}:#{range.start.line}:#{range.start.column}"
end

## The declaration with `export` when it has one; a function with `def`, since its signature does not hold it.
export def declaration_text(kind: String, exported: Bool, signature: String) -> String
  head = signature
  if kind == "function"
    head = "def #{head}"
  end

  return "export #{head}" if exported

  head
end

## `field Struct.name: Type`, with ` = default` as written when `default` is not "".
export def field_text(owner: String, name: String, type: String, default: String) -> String
  return "field #{owner}.#{name}: #{type} = #{default}" if default != ""

  "field #{owner}.#{name}: #{type}"
end

## `variant Enum.Name(Payload)`, the variant written as its signature.
export def variant_text(owner: String, signature: String) -> String = "variant #{owner}.#{signature}"

# `import Models from "models"` or `import {A, B as C} from "models"`.
def import_text(declaration: Model.Import) -> String
  return "import #{declaration.alias} from \"#{declaration.path}\"" if declaration.alias != ""

  names = declaration.names.map do |name: Model.ImportName| imported_name(name) end
  "import {#{names.join(", ")}} from \"#{declaration.path}\""
end

def imported_name(name: Model.ImportName) -> String
  return name.name if name.local == name.name

  "#{name.name} as #{name.local}"
end

# The line of the item, the lines of its fields or variants, and those of the declarations of a module block.
def item_lines(file: String, item: Model.Item) -> List[String]
  lines = ["#{place(file, item.range)} #{declaration_text(item.kind, item.exported, item.signature)}"]
  lines = lines.concat(member_lines(file, item))
  for inner in item.items
    lines = lines.concat(item_lines(file, inner))
  end

  lines
end

# `field Struct.name: Type` and `variant Enum.Name(Payload)`, one line each, at the position of the name.
def member_lines(file: String, item: Model.Item) -> List[String]
  fields = item.fields.map do |field: Model.Field|
    "#{place(file, field.name_range)} #{field_text(item.name, field.name, field.type, field.default)}"
  end

  variants = item.variants.map do |variant: Model.Variant| variant_line(file, item.name, variant) end
  fields.concat(variants)
end

def variant_line(file: String, enum_name: String, variant: Model.Variant) -> String
  written = Signature.variant_text(variant.name, variant.payload)
  "#{place(file, variant.name_range)} #{variant_text(enum_name, written)}"
end
