## The Markdown form of `agentica doc` (docs/future/32-doc-comments.md, 32.5): a heading with the module path, the
## module doc, then each exported declaration in source order as a heading with its signature, its doc, and the fields
## of a struct or the variants of an enum with their docs. An export without a doc is listed with its signature only.
## The docs are printed as written, with the `##` markers removed.

import Ast from "../syntax/ast"
import Model from "doc_model"
import Signature from "signature"

## The text of a documented module, ending with a line feed. `module` is the path as the user typed it.
export def text(module: String, documented: Model.Module) -> String
  blocks = ["# #{module}"]
  case documented.doc
    some(doc) -> blocks = blocks.push(doc)
    none -> blocks = blocks
  end

  for item in documented.items
    blocks = blocks.concat(item_blocks(item))
  end

  return "#{blocks.join("\n\n")}\n"
end

## One list line per field or variant: `signature` and, when it has a doc, a dash and the doc. `agentica help std/`
## prints the same lines.
export def part_lines(detail: Model.Detail) -> List[String]
  case detail
    Model.Detail.Struct(fields) ->
      return fields.map do |field: Model.Field| part_line(field_signature(field), field.doc) end
    Model.Detail.Enum(variants) -> return variants.map do |variant: Model.Variant| variant_line(variant) end
    Model.Detail.Function(_, _) -> return []
    Model.Detail.Plain -> return []
  end
end

# The blocks of one item, each separated from the next by a blank line: the heading, the doc, the list of its parts.
def item_blocks(item: Model.Item) -> List[String]
  blocks = ["## `#{item.signature}`"]
  case item.doc
    some(doc) -> blocks = blocks.push(doc)
    none -> blocks = blocks
  end

  parts = part_lines(item.detail)
  if parts.size > 0
    blocks = blocks.push(parts.join("\n"))
  end

  return blocks
end

# `name: Type`, with ` = default` as written when the field has one.
def field_signature(field: Model.Field) -> String
  typed = "#{field.name}: #{field.type}"
  case field.default
    some(written) -> return "#{typed} = #{written}"
    none -> return typed
  end
end

def variant_line(variant: Model.Variant) -> String
  return part_line(Signature.variant_text(variant.name, variant.payload), variant.doc)
end

# A doc of several lines continues under the dash, indented.
def part_line(signature: String, doc: Optional[String]) -> String
  case doc
    some(text) -> return "- `#{signature}` - #{text.split("\n").join("\n  ")}"
    none -> return "- `#{signature}`"
  end
end
