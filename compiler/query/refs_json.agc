## The JSON form of `agentica refs` (docs/future/39-semantic-cli.md, 39.5): `{version, command, query, definition,
## builtin, references, skipped}`. `definition` is null for a builtin, which `builtin` names; else it is the match that
## `symbol` gives the declaration (symbol_json.agc, same fields), a local included, with the kind of the binding.
## Each reference is `{kind, function, span}`, the `span` being the name alone and `function` null at the top level.
## `skipped` is as for `symbol`. A span is `{file, range}` with the `file` the command answers with. An answer from a
## program that does not check (39.6) adds `partial` (true) and `diagnostics`.

import Model from "../analysis/model"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"
import SymbolJson from "symbol_json"

## The object of the answer.
export def json(found: Model.Refs) -> Json
  shape = {
    "version": JSON.from(found.version),
    "command": JSON.from("refs"),
    "query": JSON.from(found.query),
    "definition": definition_json(found.definition),
    "builtin": DocJson.text_json(found.builtin),
    "references": JSON.array(found.references.map do |use: Model.Reference| reference_json(use) end),
    "skipped": JSON.array(found.skipped.map do |left: Model.Skipped| skipped_json(left) end),
  }
  if found.partial
    return JSON.object(DiagnosticJson.partial(shape, found.diagnostics))
  end
  return JSON.object(shape)
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

def definition_json(definition: List[Model.Symbol]) -> Json
  if definition.size == 0
    return JSON.null()
  end
  return SymbolJson.match_json(definition[0])
end
