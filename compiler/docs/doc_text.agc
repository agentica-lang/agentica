## The Markdown form of `agentica doc`: a heading with the module path, the
## module doc, then each exported declaration in source order as a heading with its signature, its doc, and the fields
## of a struct or the variants of an enum with their docs. An export without a doc is listed with its signature only.
## The docs are printed as written, with the `##` markers removed.

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

  "#{blocks.join("\n\n")}\n"
end

## One list line per field or variant: `signature` and, when it has a doc, a dash and the doc, then a line that says a
## struct has private fields, which are not listed. `agentica help std/` prints the same lines.
export def part_lines(item: Model.Item) -> List[String]
  case item.detail
    Model.Detail.Struct(fields) ->
      lines = fields.map do |field: Model.Field| part_line(field_signature(field), field.doc) end
      return lines.push("- and private fields") if item.private_line.some?

      lines
    Model.Detail.Enum(variants) -> variants.map do |variant: Model.Variant| variant_line(variant) end
    Model.Detail.Function(_, _) -> []
    Model.Detail.Module(_) -> []
    Model.Detail.Plain -> []
  end
end

# The blocks of one item, each separated from the next by a blank line: the heading, the doc, the list of its parts.
def item_blocks(item: Model.Item) -> List[String]
  blocks = ["## `#{item.signature}`"]
  case item.doc
    some(doc) -> blocks = blocks.push(doc)
    none -> blocks = blocks
  end

  parts = part_lines(item)
  if parts.size > 0
    blocks = blocks.push(parts.join("\n"))
  end

  case item.detail
    # The declarations of a module block follow it, one heading level down.
    Model.Detail.Module(items) ->
      for inner in items
        blocks = blocks.concat(item_blocks(inner).map do |block: String| nested_block(block) end)
      end

    _ -> blocks = blocks
  end

  blocks
end

def nested_block(block: String) -> String
  return "##{block}" if block.start_with?("#")

  block
end

# `name: Type`, with ` = default` as written when the field has one.
def field_signature(field: Model.Field) -> String
  typed = "#{field.name}: #{field.type}"
  case field.default
    some(written) -> "#{typed} = #{written}"
    none -> typed
  end
end

def variant_line(variant: Model.Variant) -> String
  part_line(Signature.variant_text(variant.name, variant.payload), variant.doc)
end

# A doc of several lines continues under the dash, indented.
def part_line(signature: String, doc: Optional[String]) -> String
  case doc
    some(text) -> "- `#{signature}` - #{text.split("\n").join("\n  ")}"
    none -> "- `#{signature}`"
  end
end
