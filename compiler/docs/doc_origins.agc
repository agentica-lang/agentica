## The original declarations behind the re-exports of a file (`export Url.parse`), for `agentica doc` and `agentica
## outline`. Both only parse the file, but a re-export names a declaration of another file, so the file is linked when
## it re-exports something. A file that does not link lists no re-export: its imports may be missing, and the two
## commands never fail for that. A std/ module may re-export a builtin record or enum of a std-only family
## (`export LogRegistry.Event`), which no file declares: its item comes from the catalog.

import Builtins from "../catalog/builtins"
import {ENUMS, RECORDS, STD_ONLY} from "../catalog/builtins"
import Catalog from "../catalog/builtin_model"
import Declarations from "../modules/declarations"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import Model from "doc_model"

## The item of the original declaration of each name that `program`, the parse of the file at `path`, re-exports. It is
## empty for a file that re-exports nothing, and holds only the builtin types for one that does not link.
export def of_file(settings: Env.Settings, path: String, program: Ast.Program) -> Map[String, Model.Item]
  builtins = builtin_items(path, program)
  return builtins if Declarations.reexports_of(program.declarations).size == builtins.size

  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) -> joined(of_linked(linked), builtins)
    Linker.Linking.Failed(_) -> builtins
  end
end

def joined(found: Map[String, Model.Item], more: Map[String, Model.Item]) -> Map[String, Model.Item]
  more.keys.reduce(found) do |all, name| all.put(name, more[name]) end
end

# The items of the builtin types that a std/ module re-exports from a std-only family it does not import. They need
# no link, and a std/ module given by its std/ path does not link as a root.
def builtin_items(path: String, program: Ast.Program) -> Map[String, Model.Item]
  return {} if !path.start_with?("std/")

  aliases = Declarations.imports_of(program.declarations).map do |decl: Ast.ImportDecl| Declarations.alias_of(decl) end
  items: Map[String, Model.Item] = {}
  for decl in Declarations.reexports_of(program.declarations)
    target = "#{decl.alias}.#{decl.name}"
    if STD_ONLY.has_key?(decl.alias) and !aliases.include?(decl.alias)
      if Builtins.type_named?(target)
        items = items.put(decl.name, builtin_item(decl.name, target))
      end
    end
  end

  items
end

# The root file comes first in a linked program. The linked name of the original is its file's "@N::" prefix and its
# own name. The items of a file are built once, the first time a name needs the file, and each name is a lookup.
def of_linked(linked: Linker.Linked) -> Map[String, Model.Item]
  files: Map[String, Linker.LinkedModule] = {}
  for module in linked.modules
    if module.prefix != ""
      files = files.put(module.prefix, module)
    end
  end

  built: Map[String, Map[String, Model.Item]] = {}
  origins: Map[String, Model.Item] = {}
  root = linked.modules[0]
  for name in root.reexported.keys
    target = root.reexported[name]
    own = T.display_name(target)
    prefix = target.slice(0, target.length - own.length)
    next if !files.has_key?(prefix)

    if !built.has_key?(prefix)
      built = built.put(prefix, items_by_name(files[prefix]))
    end

    found = built[prefix].get(own)
    if found.some?
      origins = origins.put(name, found.unwrap!)
    end
  end

  origins
end

# The item of a builtin record, enum or opaque type that a std/ module re-exports as `name`. Its spans are
# placeholders: the item takes the place of the `export` line (Model.reexport_items). Types print with the builtin
# names, which a value and a message show too.
def builtin_item(name: String, target: String) -> Model.Item
  at = Source.Position(offset: 0, line: 1, column: 1)
  span = Source.Span(start: at, stop: at)
  if !RECORDS.has_key?(target) and !ENUMS.has_key?(target)
    return builtin_shape("resource", name, span, "The builtin handle `#{target}`.", Model.Detail.Plain)
  elsif RECORDS.has_key?(target)
    fields = RECORDS[target].map do |field: Catalog.Named|
      default: Optional[String] = none
      if Builtins.default_present?(field.default)
        default = some(Builtins.default_text(field.default))
      end

      type = T.to_text(field.type)
      Model.Field(name: field.name, span: span, name_span: span, type: type, default: default, doc: none)
    end

    doc = "The builtin record `#{target}`."
    return builtin_shape("struct", name, span, doc, Model.Detail.Struct(fields))
  end

  variants = ENUMS[target].variants.map do |variant: Catalog.Variant|
    payload = variant.payload.map do |type: T.Type| T.to_text(type) end
    Model.Variant(name: variant.name, span: span, name_span: span, payload: payload, doc: none)
  end

  builtin_shape("enum", name, span, "The builtin enum `#{target}`.", Model.Detail.Enum(variants))
end

def builtin_shape(kind: String, name: String, span: Source.Span, doc: String, detail: Model.Detail) -> Model.Item
  Model.Item(
    kind: kind,
    name: name,
    name_span: span,
    exported: true,
    signature: "#{kind} #{name}",
    doc: some(doc),
    span: span,
    detail: detail,
  )
end

# The declarations of a file by their own name.
def items_by_name(module: Linker.LinkedModule) -> Map[String, Model.Item]
  items: Map[String, Model.Item] = {}
  for item in Model.declared(module.parsed, module.text)
    items = items.put(item.name, item)
  end

  items
end
