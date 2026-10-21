## The JSON form of `agentica outline` (docs/future/39-semantic-cli.md, 39.5): `{version, command, file, doc, imports,
## items}`. Each item is the item of `agentica doc` (docs/doc_json.agc) with `exported` and the `name_span` of the item
## and of each field and variant. A span is `{file, range}` with the `file` the command answers with.

import Ast from "../syntax/ast"
import DocJson from "../docs/doc_json"
import DocModel from "../docs/doc_model"
import Outline from "outline"

## The version of the shape. A key may be added within a version; one that changes meaning gets a new version.
export VERSION = 1

## The object of the outline of `file`, the name the answer gives it (query_files.agc, `display`).
export def json(file: String, outlined: Outline.Outline) -> Json
  imports = outlined.imports.map do |declaration: Ast.ImportDecl| import_json(file, declaration) end
  items = outlined.items.map do |item: DocModel.Item| DocJson.item_json(file, item, true) end
  return JSON.object({
    "version": JSON.from(VERSION),
    "command": JSON.from("outline"),
    "file": JSON.from(file),
    "doc": DocJson.text_json(outlined.doc),
    "imports": JSON.array(imports),
    "items": JSON.array(items),
  })
end

# `{path, alias, names, span}`: `alias` is null for an import with a list of names, and `names` is empty for one
# with an alias.
def import_json(file: String, declaration: Ast.ImportDecl) -> Json
  names = declaration.names.map do |name: Ast.ImportName|
    JSON.object({
      "name": JSON.from(name.name),
      "local": JSON.from(name.local),
      "span": DocJson.span_json(file, name.span),
    })
  end
  return JSON.object({
    "path": JSON.from(declaration.path),
    "alias": DocJson.text_json(declaration.alias),
    "names": JSON.array(names),
    "span": DocJson.span_json(file, declaration.span),
  })
end
