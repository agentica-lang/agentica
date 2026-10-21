## The JSON form of `agentica symbol` (docs/future/39-semantic-cli.md, 39.5): `{version, command, query, matches,
## skipped}`. A match is `{kind, name, module, exported, signature, doc, span, name_span}`, and a field adds `type` and
## `struct`, a variant `payload` and `enum`, a builtin `help` (the object of `agentica help NAME --json`) with
## `module`, `span` and `name_span` null. `doc` is the whole `##` text or null. A skipped root is `{file, diagnostic}`,
## the diagnostic being the `--json` object of the problem. A span is `{file, range}` with the `file` the command
## answers with, which is `module`.

import Model from "../analysis/model"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"

## The object of the answer; the `module` of each match is the name the answer gives its file (query_files.agc,
## `display`).
export def json(found: Model.Symbols) -> Json
  return JSON.object({
    "version": JSON.from(found.version),
    "command": JSON.from("symbol"),
    "query": JSON.from(found.query),
    "matches": JSON.array(found.matches.map do |match: Model.Symbol| match_json(match) end),
    "skipped": JSON.array(found.skipped.map do |left: Model.Skipped| skipped_json(left) end),
  })
end

## The object of one match, which `refs` gives its `definition` as well.
export def match_json(match: Model.Symbol) -> Json
  if match.kind == "builtin"
    return JSON.object({
      "kind": JSON.from(match.kind),
      "name": JSON.from(match.name),
      "module": JSON.null(),
      "exported": JSON.from(match.exported),
      "signature": JSON.from(match.signature),
      "doc": JSON.null(),
      "span": JSON.null(),
      "name_span": JSON.null(),
      "help": match.help,
    })
  end
  fields: Map[String, Json] = {
    "kind": JSON.from(match.kind),
    "name": JSON.from(match.name),
    "module": JSON.from(match.module),
    "exported": JSON.from(match.exported),
    "signature": JSON.from(match.signature),
    "doc": DocJson.text_json(match.doc),
    "span": DocJson.span_json(match.module, match.range),
    "name_span": DocJson.span_json(match.module, match.name_range),
  }
  if match.kind == "field"
    return JSON.object(fields.put("type", JSON.from(match.type)).put("struct", JSON.from(match.owner)))
  elsif match.kind == "variant"
    written = JSON.array(match.payload.map do |type: String| JSON.from(type) end)
    return JSON.object(fields.put("payload", written).put("enum", JSON.from(match.owner)))
  end
  return JSON.object(fields)
end

def skipped_json(left: Model.Skipped) -> Json
  return JSON.object({"file": JSON.from(left.file), "diagnostic": DiagnosticJson.object(left.diagnostic)})
end
