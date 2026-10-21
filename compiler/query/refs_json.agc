## The JSON form of `agentica refs` (docs/future/39-semantic-cli.md, 39.5): `{version, command, query, definition,
## builtin, references, skipped}`. `definition` is null for a builtin, which `builtin` names; else it has the `kind`,
## `name`, `module` (the file), `exported`, `signature`, `span` (the whole declaration) and `name_span` of the
## declaration, and the `struct` of a field or the `enum` of a variant. Each reference is `{kind, function, span}`, the
## `span` being the name alone and `function` null at the top level. `skipped` is always empty for now: a position
## names one file. A span is `{file, range}` with the `file` the command answers with.

import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"
import Model from "../analysis/model"

## The object of the answer.
export def json(found: Model.Refs) -> Json
  return JSON.object({
    "version": JSON.from(found.version),
    "command": JSON.from("refs"),
    "query": JSON.from(found.query),
    "definition": definition_json(found.definition),
    "builtin": DocJson.text_json(found.builtin),
    "references": JSON.array(found.references.map do |use: Model.Reference| reference_json(use) end),
    "skipped": JSON.array(found.skipped.map do |left: Model.Skipped| skipped_json(left) end),
  })
end

def skipped_json(left: Model.Skipped) -> Json
  return JSON.object({"file": JSON.from(left.file), "diagnostic": DiagnosticJson.object(left.diagnostic)})
end

def reference_json(use: Model.Reference) -> Json
  return JSON.object({
    "kind": JSON.from(use.kind),
    "function": DocJson.text_json(use.function),
    "span": DocJson.span_json(use.file, use.range),
  })
end

def definition_json(definition: List[Model.Declaration]) -> Json
  if definition.size == 0
    return JSON.null()
  end
  found = definition[0]
  shape = {
    "kind": JSON.from(found.kind),
    "name": JSON.from(found.name),
    "module": JSON.from(found.module),
    "exported": JSON.from(found.exported),
    "signature": JSON.from(found.signature),
    "span": DocJson.span_json(found.module, found.range),
    "name_span": DocJson.span_json(found.module, found.name_range),
  }
  if found.kind == "field"
    shape = shape.put("struct", JSON.from(found.owner))
  elsif found.kind == "variant"
    shape = shape.put("enum", JSON.from(found.owner))
  end
  return JSON.object(shape)
end
