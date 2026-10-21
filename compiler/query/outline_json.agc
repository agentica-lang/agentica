## The JSON form of `agentica outline` (docs/future/39-semantic-cli.md, 39.5): `{version, command, file, doc, imports,
## items}`. Each item is the item of `agentica doc` (docs/doc_json.agc) with `exported` and the `name_span` of the item
## and of each field and variant. A span is `{file, range}` with the `file` the command answers with.

import DocJson from "../docs/doc_json"
import Model from "../analysis/model"

## The object of the outline; `file` is the name the answer gives the file (query_files.agc, `display`).
export def json(outlined: Model.Outline) -> Json
  file = outlined.file
  imports = outlined.imports.map do |declaration: Model.Import| import_json(file, declaration) end
  items = outlined.items.map do |item: Model.Item| DocJson.item_json(file, item, true) end
  return JSON.object({
    "version": JSON.from(outlined.version),
    "command": JSON.from("outline"),
    "file": JSON.from(file),
    "doc": DocJson.text_json(outlined.doc),
    "imports": JSON.array(imports),
    "items": JSON.array(items),
  })
end

# `{path, alias, names, span}`: `alias` is null for an import with a list of names, and `names` is empty for one
# with an alias.
def import_json(file: String, declaration: Model.Import) -> Json
  names = declaration.names.map do |name: Model.ImportName|
    JSON.object({
      "name": JSON.from(name.name),
      "local": JSON.from(name.local),
      "span": DocJson.span_json(file, name.range),
    })
  end
  return JSON.object({
    "path": JSON.from(declaration.path),
    "alias": DocJson.text_json(declaration.alias),
    "names": JSON.array(names),
    "span": DocJson.span_json(file, declaration.range),
  })
end
