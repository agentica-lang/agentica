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
  items = documented.items.map do |item: Model.Item| item_json(module, item, false) end
  return JSON.object({
    "module": JSON.from(module),
    "doc": text_json(documented.doc),
    "items": JSON.array(items),
  })
end

## `{kind, name, signature, summary, doc, span}` and, by kind, the parameters and the result, the fields or the
## variants. `located` adds what `agentica outline` lists: `exported` and the `name_span` of the item and of each field
## or variant.
export def item_json(module: String, item: Model.Item, located: Bool) -> Json
  fields: Map[String, Json] = {
    "kind": JSON.from(item.kind),
    "name": JSON.from(item.name),
    "signature": JSON.from(item.signature),
    "summary": text_json(Model.summary(item.doc)),
    "doc": text_json(item.doc),
    "span": span_json(module, item.span),
  }
  if located
    fields = fields.put("exported", JSON.from(item.exported))
    fields = fields.put("name_span", span_json(module, item.name_span))
  end
  case item.detail
    Model.Detail.Function(parameters, result) ->
      fields = fields.put("parameters", JSON.array(parameters.map do |parameter: Model.Parameter|
        parameter_json(parameter)
      end))
      fields = fields.put("result", JSON.from(result))
    Model.Detail.Struct(members) ->
      members_json = members.map do |member: Model.Field| field_json(module, member, located) end
      fields = fields.put("fields", JSON.array(members_json))
    Model.Detail.Enum(variants) ->
      variants_json = variants.map do |variant: Model.Variant| variant_json(module, variant, located) end
      fields = fields.put("variants", JSON.array(variants_json))
    Model.Detail.Plain -> fields = fields
  end
  return JSON.object(fields)
end

## `{file, range}`: the two keys a diagnostic puts at its top level, in an object of their own.
export def span_json(module: String, span: Source.Span) -> Json
  return JSON.object({"file": JSON.from(module), "range": DiagnosticJson.range(span)})
end

## The text, or null when it is absent.
export def text_json(text: Ast.Optional[String]) -> Json
  case text
    Ast.Optional.Present(value) -> return JSON.from(value)
    Ast.Optional.Absent -> return JSON.null()
  end
end

def parameter_json(parameter: Model.Parameter) -> Json
  return JSON.object({
    "name": JSON.from(parameter.name),
    "type": JSON.from(parameter.type),
    "default": text_json(parameter.default),
  })
end

def field_json(module: String, field: Model.Field, located: Bool) -> Json
  fields: Map[String, Json] = {
    "name": JSON.from(field.name),
    "type": JSON.from(field.type),
    "doc": text_json(field.doc),
  }
  if located
    fields = fields.put("name_span", span_json(module, field.name_span))
  end
  return JSON.object(fields)
end

def variant_json(module: String, variant: Model.Variant, located: Bool) -> Json
  payload = variant.payload.map do |type: String| JSON.from(type) end
  fields: Map[String, Json] = {
    "name": JSON.from(variant.name),
    "payload": JSON.array(payload),
    "doc": text_json(variant.doc),
  }
  if located
    fields = fields.put("name_span", span_json(module, variant.name_span))
  end
  return JSON.object(fields)
end
