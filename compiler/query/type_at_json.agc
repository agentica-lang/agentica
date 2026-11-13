## The JSON form of `agentica type-at` (docs/grammar/06b-builtins.md): `{version, command, position, kind,
## text, type, span, definition, help}`. `definition` is null or the span of the declaration (`{file, range}`) with
## its `kind`, its `name`, the `name_span` of the name, its `signature` and its `doc` (the whole `##` text or null).
## `help` is null, or the object of `agentica help NAME --json` for a `builtin` answer, which has no definition. A
## span is `{file, range}` with the `file` the command answers with. An answer from a program that does not check
## adds `partial` (true) and `diagnostics`, and has a `type` of null where only the link knows the name.

import Model from "../analysis/model"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"

## The object of the answer. Every range is in the file of `position`, except that of the definition.
def json(found: Model.TypeAt) -> JSON.Value
  file = found.position.file
  shape = {
    "version": JSON.from(found.version),
    "command": JSON.from("type-at"),
    "position": JSON.object({
      "file": JSON.from(file),
      "line": JSON.from(found.position.line),
      "column": JSON.from(found.position.column),
    }),
    "kind": JSON.from(found.kind),
    "text": JSON.from(found.text),
    "type": JSON.from(found.type),
    "span": DocJson.span_json(file, found.range),
    "definition": definition_json(found.definition),
    "help": found.help,
  }

  return JSON.object(DiagnosticJson.partial(shape.put("type", typed(found.type)), found.diagnostics)) if found.partial

  JSON.object(shape)
end

private

# The type, or null for a name that only the link could answer.
def typed(type: String) -> JSON.Value
  return JSON.null() if type == ""

  JSON.from(type)
end

# `{file, range, kind, name, name_span}`, or null for what no file declares.
def definition_json(definition: List[Model.Definition]) -> JSON.Value
  return JSON.null() if definition.size == 0

  found = definition[0]
  JSON.object({
    "file": JSON.from(found.file),
    "range": DiagnosticJson.range(found.range),
    "kind": JSON.from(found.kind),
    "name": JSON.from(found.name),
    "name_span": DocJson.span_json(found.file, found.name_range),
    "signature": JSON.from(found.signature),
    "doc": DocJson.text_json(found.doc),
  })
end
