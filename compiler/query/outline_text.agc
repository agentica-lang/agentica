## The text form of `agentica outline` (docs/future/39-semantic-cli.md, 39.2): one line per declaration, so the
## output reads like `rg`: `file:line:column` first, then the declaration as it is written in the source. A struct's
## fields and an enum's variants follow their declaration, each at the position of its name. Docs are in the JSON form
## only.

import Ast from "../syntax/ast"
import DocModel from "../docs/doc_model"
import Outline from "outline"
import Signature from "../docs/signature"
import Source from "../syntax/source"

## The text of the outline of `file`, one line each and a line feed at the end of every line; empty for an empty file.
export def text(file: String, outlined: Outline.Outline) -> String
  lines: List[String] = []
  for declaration in outlined.imports
    lines = lines.push("#{place(file, declaration.span)} #{import_text(declaration)}")
  end
  for item in outlined.items
    lines = lines.push("#{place(file, item.span)} #{declaration_text(item.kind, item.exported, item.signature)}")
    lines = lines.concat(member_lines(file, item))
  end
  if lines.size == 0
    return ""
  end
  return "#{lines.join("\n")}\n"
end

## `file:line:column`, the start of `span`, which `rg` prints in front of a hit.
export def place(file: String, span: Source.Span) -> String
  return "#{file}:#{span.start.line}:#{span.start.column}"
end

## The declaration with `export` when it has one; a function with `def`, since its signature does not hold it.
export def declaration_text(kind: String, exported: Bool, signature: String) -> String
  head = signature
  if kind == "function"
    head = "def #{head}"
  end
  if exported
    return "export #{head}"
  end
  return head
end

## `field Struct.name: Type`.
export def field_text(owner: String, name: String, type: String) -> String
  return "field #{owner}.#{name}: #{type}"
end

## `variant Enum.Name(Payload)`, the variant written as its signature.
export def variant_text(owner: String, signature: String) -> String
  return "variant #{owner}.#{signature}"
end

# `import Models from "models"` or `import {A, B as C} from "models"`.
def import_text(declaration: Ast.ImportDecl) -> String
  case declaration.alias
    Ast.Optional.Present(alias) -> return "import #{alias} from \"#{declaration.path}\""
    Ast.Optional.Absent ->
      names = declaration.names.map do |name: Ast.ImportName| imported_name(name) end
      return "import {#{names.join(", ")}} from \"#{declaration.path}\""
  end
end

def imported_name(name: Ast.ImportName) -> String
  if name.local == name.name
    return name.name
  end
  return "#{name.name} as #{name.local}"
end

# `field Struct.name: Type` and `variant Enum.Name(Payload)`, one line each, at the position of the name.
def member_lines(file: String, item: DocModel.Item) -> List[String]
  case item.detail
    DocModel.Detail.Struct(fields) ->
      return fields.map do |field: DocModel.Field|
        "#{place(file, field.name_span)} #{field_text(item.name, field.name, field.type)}"
      end
    DocModel.Detail.Enum(variants) ->
      return variants.map do |variant: DocModel.Variant|
        written = Signature.variant_text(variant.name, variant.payload)
        "#{place(file, variant.name_span)} #{variant_text(item.name, written)}"
      end
    DocModel.Detail.Function(_, _) -> return []
    DocModel.Detail.Plain -> return []
  end
end
