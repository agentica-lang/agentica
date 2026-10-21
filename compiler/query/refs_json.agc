## The JSON form of `agentica refs` (docs/future/39-semantic-cli.md, 39.5): `{version, command, query, definition,
## builtin, references, skipped}`. `definition` is null for a builtin, which `builtin` names; else it has the `kind`,
## `name`, `module` (the file), `exported`, `signature`, `span` (the whole declaration) and `name_span` of the
## declaration, and the `struct` of a field or the `enum` of a variant. Each reference is `{kind, function, span}`, the
## `span` being the name alone and `function` null at the top level. `skipped` is always empty for now: a position
## names one file. A span is `{file, range}`, with the name that `names` gives the file.

import Ast from "../syntax/ast"
import DocJson from "../docs/doc_json"
import Definitions from "definitions"
import Position from "query_position"
import Refs from "refs"

## The version of the shape. A key may be added within a version; one that changes meaning gets a new version.
export VERSION = 1

## The object of `answered`, for the position `asked`. `names` gives the name that the answer uses for each file
## (query_files.agc, `display`).
export def json(names: Map[String, String], asked: Position.Asked, answered: Refs.Answer) -> Json
  return JSON.object({
    "version": JSON.from(VERSION),
    "command": JSON.from("refs"),
    "query": JSON.from("#{asked.file}:#{asked.line}:#{asked.column}"),
    "definition": definition_json(names, answered),
    "builtin": builtin_json(answered.builtin),
    "references": JSON.array(answered.references.map do |found: Refs.Reference| reference_json(names, found) end),
    "skipped": JSON.array([]),
  })
end

def builtin_json(name: String) -> Json
  if name == ""
    return JSON.null()
  end
  return JSON.from(name)
end

def reference_json(names: Map[String, String], found: Refs.Reference) -> Json
  function = JSON.null()
  if found.function != ""
    function = JSON.from(found.function)
  end
  return JSON.object({
    "kind": JSON.from(found.kind),
    "function": function,
    "span": DocJson.span_json(file_name(names, found.file), found.span),
  })
end

def definition_json(names: Map[String, String], answered: Refs.Answer) -> Json
  case answered.definition
    Ast.Optional.Absent -> return JSON.null()
    Ast.Optional.Present(found) ->
      file = file_name(names, found.file)
      shape = {
        "kind": JSON.from(found.kind),
        "name": JSON.from(found.name),
        "module": JSON.from(file),
        "exported": JSON.from(found.exported),
        "signature": JSON.from(found.signature),
        "span": DocJson.span_json(file, found.span),
        "name_span": DocJson.span_json(file, found.name_span),
      }
      if found.kind == "field"
        shape = shape.put("struct", JSON.from(answered.owner))
      elsif found.kind == "variant"
        shape = shape.put("enum", JSON.from(answered.owner))
      end
      return JSON.object(shape)
  end
end

# The name the answer gives a file; the file as the linker names it when the command did not name it.
def file_name(names: Map[String, String], file: String) -> String
  return names.get(file, file)
end
