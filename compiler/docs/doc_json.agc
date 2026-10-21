## The JSON form of `agentica doc` (docs/future/32-doc-comments.md, 32.5). Each key means the same wherever it appears:
## `doc` is the whole text of the `##` block or null, `summary` its first paragraph or null, `span` the declaration
## with its `file`, every type a string as written.

import Ast from "../syntax/ast"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Model from "doc_model"
import Source from "../syntax/source"

## The object `{module, doc, items}` of a documented module. `module` is the path as the user typed it, and the `file`
## of each span.
export def json(module: String, documented: Model.Module) -> Json
  items = documented.items.map do |item: Model.Item| item_json(module, item) end
  return JSON.object({
    "module": JSON.from(module),
    "doc": text_json(documented.doc),
    "items": JSON.array(items),
  })
end

# `{kind, name, signature, summary, doc, span}` and, by kind, the parameters and the result, the fields or the
# variants.
def item_json(module: String, item: Model.Item) -> Json
  fields: Map[String, Json] = {
    "kind": JSON.from(item.kind),
    "name": JSON.from(item.name),
    "signature": JSON.from(item.signature),
    "summary": text_json(Model.summary(item.doc)),
    "doc": text_json(item.doc),
    "span": span_json(module, item.span),
  }
  case item.detail
    Model.Detail.Function(parameters, result) ->
      fields = fields.put("parameters", JSON.array(parameters.map do |parameter: Model.Parameter|
        parameter_json(parameter)
      end))
      fields = fields.put("result", JSON.from(result))
    Model.Detail.Struct(members) ->
      fields = fields.put("fields", JSON.array(members.map do |member: Model.Field| field_json(member) end))
    Model.Detail.Enum(variants) ->
      fields = fields.put("variants", JSON.array(variants.map do |variant: Model.Variant| variant_json(variant) end))
    Model.Detail.Plain -> fields = fields
  end
  return JSON.object(fields)
end

def parameter_json(parameter: Model.Parameter) -> Json
  return JSON.object({"name": JSON.from(parameter.name), "type": JSON.from(parameter.type)})
end

def field_json(field: Model.Field) -> Json
  return JSON.object({
    "name": JSON.from(field.name),
    "type": JSON.from(field.type),
    "doc": text_json(field.doc),
  })
end

def variant_json(variant: Model.Variant) -> Json
  payload = variant.payload.map do |type: String| JSON.from(type) end
  return JSON.object({
    "name": JSON.from(variant.name),
    "payload": JSON.array(payload),
    "doc": text_json(variant.doc),
  })
end

# `{file, range}`: the two keys a diagnostic puts at its top level, in an object of their own.
def span_json(module: String, span: Source.Span) -> Json
  return JSON.object({"file": JSON.from(module), "range": DiagnosticJson.range(span)})
end

def text_json(text: Ast.Optional[String]) -> Json
  case text
    Ast.Optional.Present(value) -> return JSON.from(value)
    Ast.Optional.Absent -> return JSON.null()
  end
end
