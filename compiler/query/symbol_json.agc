## The JSON form of `agentica symbol` (docs/future/39-semantic-cli.md, 39.5): `{version, command, query, matches,
## skipped}`. A match is `{kind, name, module, exported, signature, doc, span, name_span}`, and a field adds `type` and
## `struct`, a variant `payload` and `enum`, a builtin `help` (the object of `agentica help NAME --json`) with
## `module`, `span` and `name_span` null. `doc` is the whole `##` text or null. A skipped root is `{file, diagnostic}`,
## the diagnostic being the `--json` object of the problem. A span is `{file, range}` with the `file` the command
## answers with, which is `module`.

import CatalogJson from "../catalog/catalog_json"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import DocJson from "../docs/doc_json"
import Symbol from "symbol"
import SymbolLink from "symbol_link"

## The version of the shape. A key may be added within a version; one that changes meaning gets a new version.
export VERSION = 1

## The object of the answer to `query`; the `file` of each match is the name the answer gives it (query_files.agc,
## `display`).
export def json(query: String, answered: Symbol.Answer) -> Json
  return JSON.object({
    "version": JSON.from(VERSION),
    "command": JSON.from("symbol"),
    "query": JSON.from(query),
    "matches": JSON.array(answered.matches.map do |match: Symbol.Match| match_json(match) end),
    "skipped": JSON.array(answered.skipped.map do |left: SymbolLink.Skipped| skipped_json(left) end),
  })
end

def skipped_json(left: SymbolLink.Skipped) -> Json
  return JSON.object({"file": JSON.from(left.file), "diagnostic": DiagnosticJson.json(left.problem)})
end

def match_json(match: Symbol.Match) -> Json
  fields: Map[String, Json] = {
    "kind": JSON.from(match.kind),
    "name": JSON.from(match.name),
    "module": JSON.from(match.file),
    "exported": JSON.from(match.exported),
    "signature": JSON.from(match.signature),
    "doc": DocJson.text_json(match.doc),
    "span": DocJson.span_json(match.file, match.span),
    "name_span": DocJson.span_json(match.file, match.name_span),
  }
  case match.extra
    Symbol.Extra.Declared -> return JSON.object(fields)
    Symbol.Extra.Field(type) ->
      return JSON.object(fields.put("type", JSON.from(type)).put("struct", JSON.from(match.owner)))
    Symbol.Extra.Variant(payload) ->
      written = JSON.array(payload.map do |type: String| JSON.from(type) end)
      return JSON.object(fields.put("payload", written).put("enum", JSON.from(match.owner)))
    Symbol.Extra.Builtin(entry) ->
      return JSON.object({
        "kind": JSON.from(match.kind),
        "name": JSON.from(match.name),
        "module": JSON.null(),
        "exported": JSON.from(match.exported),
        "signature": JSON.from(match.signature),
        "doc": JSON.null(),
        "span": JSON.null(),
        "name_span": JSON.null(),
        "help": CatalogJson.builtin(entry),
      })
  end
end
