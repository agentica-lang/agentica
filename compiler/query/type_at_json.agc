## The JSON form of `agentica type-at` (docs/future/39-semantic-cli.md, 39.5): `{version, command, position, kind,
## text, type, span, definition}`. `definition` is null or the span of the declaration (`{file, range}`) with its
## `kind`, its `name` and the `name_span` of the name. A span is `{file, range}` with the `file` the command answers
## with.

import Ast from "../syntax/ast"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"
import Definitions from "definitions"
import Position from "query_position"
import TypeAt from "type_at"

## The version of the shape. A key may be added within a version; one that changes meaning gets a new version.
export VERSION = 1

## The object of `answered`, a position `asked` in `file`, the name the answer gives the file (query_files.agc,
## `display`). `definition_file` is the name the answer gives the file of the definition, if there is one.
export def json(file: String, asked: Position.Asked, answered: TypeAt.Answer, definition_file: String) -> Json
  return JSON.object({
    "version": JSON.from(VERSION),
    "command": JSON.from("type-at"),
    "position": JSON.object({
      "file": JSON.from(file),
      "line": JSON.from(asked.line),
      "column": JSON.from(asked.column),
    }),
    "kind": JSON.from(answered.kind),
    "text": JSON.from(answered.text),
    "type": JSON.from(answered.type),
    "span": DocJson.span_json(file, answered.span),
    "definition": definition_json(answered.definition, definition_file),
  })
end

# `{file, range, kind, name, name_span}`, or null for what no file declares.
def definition_json(definition: Ast.Optional[Definitions.Definition], file: String) -> Json
  case definition
    Ast.Optional.Absent -> return JSON.null()
    Ast.Optional.Present(found) ->
      return JSON.object({
        "file": JSON.from(file),
        "range": DiagnosticJson.range(found.span),
        "kind": JSON.from(found.kind),
        "name": JSON.from(found.name),
        "name_span": DocJson.span_json(file, found.name_span),
      })
  end
end
