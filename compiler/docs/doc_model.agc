## What `agentica doc` knows about a module: the module doc and the exported
## declarations in source order, each with its signature, its doc and, for a function, a struct or an enum, the parts
## the JSON form lists. It is built from the parsed program only: nothing is linked or checked.
##
## A doc is the text of the `##` block with the markers removed (an `Optional`, as on the syntax tree) and its leading
## and trailing blank lines dropped (`cleaned`); the lexer already strips the one space after each `##`. The doc of an
## exported declaration sits on its ExportDecl, not on the declaration inside it (parser.agc, parse_declaration), so
## `item_of` reads the outer doc first and the inner one when there is none. `of_program` takes the source `text` for
## the default values of the parameters.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Signature from "signature"

## One parameter of a function: its name, its type as written and the source text of its default value.
export struct Parameter
  name: String
  type: String
  default: Optional[String]
end

## One field of a struct, with its doc, its span, the span of its name and the source text of its default value.
export struct Field
  name: String
  span: Source.Span
  name_span: Source.Span
  type: String
  default: Optional[String]
  doc: Optional[String]
end

## One variant of an enum, with the types of its payload as written, its doc, its span and the span of its name.
export struct Variant
  name: String
  span: Source.Span
  name_span: Source.Span
  payload: List[String]
  doc: Optional[String]
end

## What an item has besides the common data: the parameters and the result of a function, the fields of a struct, the
## variants of an enum, the declarations of a module block, private ones included. An alias or a constant has none.
export enum Detail
  Function(List[Parameter], String)
  Struct(List[Field])
  Enum(List[Variant])
  Module(List[Item])
  Plain
end

## One top-level declaration. `kind` is "function", "struct", "enum", "alias", "resource", "constant" or "module";
## `span` is the whole declaration, `export` included, and `name_span` the name alone. `agentica doc` lists the
## exported ones only; `agentica outline` lists all of them. A struct lists its public fields only; private_line is the
## span of its `private` line when it has private fields, which the readers show as one line.
export struct Item
  kind: String
  name: String
  name_span: Source.Span
  exported: Bool
  signature: String
  doc: Optional[String]
  span: Source.Span
  detail: Detail
  private_line: Optional[Source.Span] = none
end

## A documented module: its doc and its exported items.
export struct Module
  doc: Optional[String]
  items: List[Item]
end

## The exported API of a parsed program, in source order. Private declarations and imports are left out. `origins` maps
## each name the program re-exports to the item of the original declaration (doc_origins.agc); a re-export without an
## entry is left out.
export def of_program(program: Ast.Program, text: String, origins: Map[String, Item]) -> Module
  items = declared_through(program, text, origins).filter do |item: Item| item.exported end
  Module(doc: cleaned(program.module_doc), items: items.map do |item: Item| exported_only(item) end)
end

## Every declaration of a parsed program that is not an import, private ones included, in source order. A re-export
## (`export Url.parse`) is not a declaration of the file, so it is left out.
export def declared(program: Ast.Program, text: String) -> List[Item] = declared_through(program, text, {})

## `declared`, and the re-exports of the program as the items in `origins`: the original declaration, with its doc and
## signature, at the place of the `export` line, so every span of the item is in this file.
export def declared_through(program: Ast.Program, text: String, origins: Map[String, Item]) -> List[Item]
  items: List[Item] = []
  for declaration in program.declarations
    for item in items_of(declaration, text, origins)
      items = items.push(item)
    end
  end

  items
end

## A doc without its leading and trailing blank lines (a line of spaces is blank); absent when nothing else is left.
## The lines in between stay as written.
export def cleaned(doc: Optional[String]) -> Optional[String]
  case doc
    none -> doc
    some(text) ->
      lines = text.split("\n")
      first = 0
      while first < lines.size and lines[first].strip == ""
        first += 1
      end

      last = lines.size
      while last > first and lines[last - 1].strip == ""
        last -= 1
      end

      return none if first == last

      some(lines.drop(first).take(last - first).join("\n"))
  end
end

## The first paragraph of a doc, on one line: its lines up to the first blank one, each trimmed, joined by a space.
## `none` when the doc has no such text.
export def summary(doc: Optional[String]) -> Optional[String]
  case cleaned(doc)
    none -> none
    some(text) ->
      words: List[String] = []
      for line in text.split("\n")
        return some(words.join(" ")) if line.strip == ""

        words = words.push(line.strip)
      end

      some(words.join(" "))
  end
end

# The item a top-level declaration gives: none for an import. The doc of an `export` sits on the export.
def items_of(declaration: Ast.Decl, text: String, origins: Map[String, Item]) -> List[Item]
  case declaration
    Ast.Decl.Export(node) -> inner_items(node.declaration, node.doc, node.span, text)
    Ast.Decl.Constant(node) -> [constant_item(node, node.span, node.exported)]
    Ast.Decl.Function(node) -> [function_item(node, node.doc, node.span, false, text)]
    Ast.Decl.Struct(node) -> [struct_item(node, node.doc, node.span, false, text)]
    Ast.Decl.Enum(node) -> [enum_item(node, node.doc, node.span, false)]
    Ast.Decl.TypeAlias(node) -> [alias_item(node, node.doc, node.span, false)]
    Ast.Decl.Resource(node) -> [resource_item(node, node.doc, node.span, false)]
    Ast.Decl.Module(node) -> [module_item(node, node.doc, node.span, false, text)]
    Ast.Decl.Import(_) -> []
    Ast.Decl.Reexport(node) -> reexport_items(node, origins)
  end
end

# The item of a re-export: the original's, put at the `export` line of this file. A field or a variant has no place of
# its own in this file, so it takes the place of the name.
def reexport_items(node: Ast.ReexportDecl, origins: Map[String, Item]) -> List[Item]
  found = origins.get(node.name)
  return [] if found.none?

  origin = found.unwrap!
  [
    origin.with(
      exported: true,
      span: node.span,
      name_span: node.name_span,
      detail: placed(origin.detail, node.name_span),
      private_line: origin.private_line.map { |_: Source.Span| node.name_span },
    ),
  ]
end

def placed(detail: Detail, at: Source.Span) -> Detail
  case detail
    Detail.Struct(fields) -> Detail.Struct(fields.map do |field: Field| field.with(span: at, name_span: at) end)
    Detail.Enum(variants) -> Detail.Enum(variants.map do |variant: Variant| variant.with(span: at, name_span: at) end)
    Detail.Function(_, _) -> detail
    Detail.Module(_) -> detail
    Detail.Plain -> detail
  end
end

# The item of the declaration inside an `export`: `doc` and `span` are the ones of the export.
def inner_items(declaration: Ast.Decl, doc: Optional[String], span: Source.Span, text: String) -> List[Item]
  case declaration
    Ast.Decl.Function(node) -> [function_item(node, doc, span, true, text)]
    Ast.Decl.Struct(node) -> [struct_item(node, doc, span, true, text)]
    Ast.Decl.Enum(node) -> [enum_item(node, doc, span, true)]
    Ast.Decl.TypeAlias(node) -> [alias_item(node, doc, span, true)]
    Ast.Decl.Resource(node) -> [resource_item(node, doc, span, true)]
    Ast.Decl.Constant(node) -> [constant_item(node, span, true)]
    Ast.Decl.Module(node) -> [module_item(node, doc, span, true, text)]
    Ast.Decl.Import(_) -> []
    Ast.Decl.Reexport(_) -> []
    Ast.Decl.Export(_) -> []
  end
end

# The outer doc wins; the doc of the inner declaration is the fallback for a tree that carries it there.
def chosen(outer: Optional[String], inner: Optional[String]) -> Optional[String]
  case outer
    some(_) -> outer
    none -> inner
  end
end

def function_item(
  node: Ast.FunctionDecl,
  doc: Optional[String],
  span: Source.Span,
  exported: Bool,
  text: String,
) -> Item
  parameters = node.params.map do |parameter: Ast.Param|
    Parameter(
      name: parameter.name,
      type: Signature.type_text(parameter.type),
      default: Signature.default_text(parameter.default, text),
    )
  end

  Item(
    kind: "function",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: Signature.function_text(node, text),
    doc: cleaned(chosen(doc, node.doc)),
    span: span,
    detail: Detail.Function(parameters, Signature.type_text(node.result)),
  )
end

def struct_item(node: Ast.StructDecl, doc: Optional[String], span: Source.Span, exported: Bool, text: String) -> Item
  shown = node.fields
  private_line: Optional[Source.Span] = none
  case node.private_mark
    some(mark) ->
      shown = node.fields.take(mark.index)
      if mark.index < node.fields.size
        private_line = some(mark.span)
      end

    none -> shown = shown
  end

  fields = shown.map do |field: Ast.FieldDecl|
    Field(
      name: field.name,
      span: field.span,
      name_span: field.name_span,
      type: Signature.type_text(field.type),
      default: Signature.default_text(field.default, text),
      doc: cleaned(field.doc),
    )
  end

  Item(
    kind: "struct",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: Signature.struct_text(node),
    doc: cleaned(chosen(doc, node.doc)),
    span: span,
    detail: Detail.Struct(fields),
    private_line: private_line,
  )
end

def enum_item(node: Ast.EnumDecl, doc: Optional[String], span: Source.Span, exported: Bool) -> Item
  variants = node.variants.map do |variant: Ast.EnumVariant|
    Variant(
      name: variant.name,
      span: variant.span,
      name_span: variant.name_span,
      payload: variant.payload_types.map do |type: Ast.TypeRef| Signature.type_text(type) end,
      doc: cleaned(variant.doc),
    )
  end

  Item(
    kind: "enum",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: Signature.enum_text(node),
    doc: cleaned(chosen(doc, node.doc)),
    span: span,
    detail: Detail.Enum(variants),
  )
end

def alias_item(node: Ast.TypeAliasDecl, doc: Optional[String], span: Source.Span, exported: Bool) -> Item
  Item(
    kind: "alias",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: Signature.alias_text(node),
    doc: cleaned(chosen(doc, node.doc)),
    span: span,
    detail: Detail.Plain,
  )
end

def resource_item(node: Ast.ResourceDecl, doc: Optional[String], span: Source.Span, exported: Bool) -> Item
  word = "free"
  if node.by_ref
    word = "free_ref"
  end

  signature = "resource #{node.name}, #{word}: #{node.free}"
  if node.module != ""
    signature = "resource #{node.name}"
  end

  case node.callback
    some(callback) -> signature = Signature.callback_text(node.name, callback)
    none -> signature = signature
  end

  Item(
    kind: "resource",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: signature,
    doc: cleaned(chosen(doc, node.doc)),
    span: span,
    detail: Detail.Plain,
  )
end

# A constant carries its own doc: the parser never wraps it in an ExportDecl.
def constant_item(node: Ast.ConstDecl, span: Source.Span, exported: Bool) -> Item
  Item(
    kind: "constant",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: Signature.constant_text(node),
    doc: cleaned(node.doc),
    span: span,
    detail: Detail.Plain,
  )
end

# A module block holds no import or re-export, so its items need no origins.
def module_item(node: Ast.ModuleDecl, doc: Optional[String], span: Source.Span, exported: Bool, text: String) -> Item
  items: List[Item] = []
  for declaration in node.declarations
    items = items.concat(items_of(declaration, text, {}))
  end

  Item(
    kind: "module",
    name: node.name,
    name_span: node.name_span,
    exported: exported,
    signature: "module #{node.name}",
    doc: cleaned(chosen(doc, node.doc)),
    span: span,
    detail: Detail.Module(items),
  )
end

# A module block keeps only its exported declarations.
def exported_only(item: Item) -> Item
  case item.detail
    Detail.Module(items) -> item.with(detail: Detail.Module(items.filter do |inner: Item| inner.exported end))
    _ -> item
  end
end
