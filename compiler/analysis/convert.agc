## The answers of the stages as the plain data of model.agc: the declarations of `agentica doc`, the outline of a file
## and the answers of `type-at`, `symbol` and `refs`. The files an answer names are given by the caller
## (query_files.agc, `display`).

import Ast from "../syntax/ast"
import Builtins from "../catalog/builtins"
import CatalogJson from "../catalog/catalog_json"
import Definitions from "../query/definitions"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import DocModel from "../docs/doc_model"
import Model from "model"
import Outline from "../query/outline"
import Position from "../query/query_position"
import Refs from "../query/refs"
import Symbol from "../query/symbol"
import SymbolLink from "../query/symbol_link"
import TypeAt from "../query/type_at"

# The version of each shape.
OUTLINE_VERSION = 1
TYPE_AT_VERSION = 1
CHECKED_VERSION = 1
SYMBOL_VERSION = 1
REFS_VERSION = 1

## The declaration `declared` of a module as plain data.
export def item(declared: DocModel.Item) -> Model.Item
  parameters: List[Model.Parameter] = []
  result = ""
  fields: List[Model.Field] = []
  variants: List[Model.Variant] = []
  case declared.detail
    DocModel.Detail.Function(found, written) ->
      parameters = found.map do |parameter: DocModel.Parameter|
        Model.Parameter(name: parameter.name, type: parameter.type, default: text(parameter.default))
      end
      result = written
    DocModel.Detail.Struct(members) ->
      fields = members.map do |member: DocModel.Field|
        Model.Field(
          name: member.name,
          name_range: DiagnosticModel.range_of(member.name_span),
          type: member.type,
          doc: text(member.doc),
        )
      end
    DocModel.Detail.Enum(found) ->
      variants = found.map do |variant: DocModel.Variant|
        Model.Variant(
          name: variant.name,
          name_range: DiagnosticModel.range_of(variant.name_span),
          payload: variant.payload,
          doc: text(variant.doc),
        )
      end
    DocModel.Detail.Plain -> parameters = parameters
  end
  return Model.Item(
    kind: declared.kind,
    name: declared.name,
    name_range: DiagnosticModel.range_of(declared.name_span),
    exported: declared.exported,
    signature: declared.signature,
    summary: text(DocModel.summary(declared.doc)),
    doc: text(declared.doc),
    range: DiagnosticModel.range_of(declared.span),
    parameters: parameters,
    result: result,
    fields: fields,
    variants: variants,
  )
end

## The answer of `check` for `file`, the name the answer gives it: passed when there is no diagnostic.
export def checked(file: String, diagnostics: List[DiagnosticModel.Diagnostic]) -> Model.Checked
  return Model.Checked(version: CHECKED_VERSION, file: file, passed: diagnostics.size == 0, diagnostics: diagnostics)
end

## The outline `outlined` of the file that the answer calls `file`.
export def outline(file: String, outlined: Outline.Outline) -> Model.Outline
  return Model.Outline(
    version: OUTLINE_VERSION,
    file: file,
    doc: text(outlined.doc),
    imports: outlined.imports.map do |declaration: Ast.ImportDecl| import_of(declaration) end,
    items: outlined.items.map do |found: DocModel.Item| item(found) end,
  )
end

## The answer `found` for the position `asked`. `file` is the name the answer gives the file of the position, and
## `home` the one it gives the file of the definition.
export def type_at(file: String, asked: Position.Asked, found: TypeAt.Answer, home: String) -> Model.TypeAt
  help = JSON.null()
  signatures: List[String] = []
  case found.builtin
    Ast.Optional.Present(entry) ->
      help = CatalogJson.builtin(entry)
      signatures = Builtins.signature(entry).split("\n")
    Ast.Optional.Absent -> help = help
  end
  return Model.TypeAt(
    version: TYPE_AT_VERSION,
    position: Model.Place(file: file, line: asked.line, column: asked.column),
    kind: found.kind,
    text: found.text,
    type: found.type,
    range: DiagnosticModel.range_of(found.span),
    definition: definition_of(found.definition, home),
    help: help,
    signatures: signatures,
    partial: false,
    diagnostics: [],
  )
end

## The answer `found` for `query`. Each match and skipped file is already named as the answer names it.
export def symbols(query: String, found: Symbol.Answer) -> Model.Symbols
  return Model.Symbols(
    version: SYMBOL_VERSION,
    query: query,
    matches: found.matches.map do |match: Symbol.Match| symbol(match) end,
    skipped: found.skipped.map do |left: SymbolLink.Skipped| skipped_of(left) end,
  )
end

## The answer `found` of `refs` for `query`, with the roots left out. `names` gives the name the answer gives each file
## (a file it does not hold keeps the name the linker gives it).
export def refs(
  query: String,
  found: Refs.Answer,
  skipped: List[SymbolLink.Skipped],
  names: Map[String, String],
) -> Model.Refs
  definition: List[Model.Symbol] = []
  case found.definition
    Ast.Optional.Present(declared) ->
      definition = [symbol(declared.with(file: names.get(declared.file, declared.file)))]
    Ast.Optional.Absent -> definition = definition
  end
  return Model.Refs(
    version: REFS_VERSION,
    query: query,
    definition: definition,
    builtin: found.builtin,
    references: found.references.map do |use: Refs.Reference|
      Model.Reference(
        kind: use.kind,
        function: use.function,
        file: names.get(use.file, use.file),
        range: DiagnosticModel.range_of(use.span),
      )
    end,
    skipped: skipped.map do |left: SymbolLink.Skipped| skipped_of(left) end,
    partial: false,
    diagnostics: [],
  )
end

## The text of an optional one. The docs and defaults of an item have been through `DocModel.cleaned`, which turns a
## blank one into Absent, and an alias is never empty, so absent and "" mean the same.
export def text(value: Ast.Optional[String]) -> String
  case value
    Ast.Optional.Present(written) -> return written
    Ast.Optional.Absent -> return ""
  end
end

def skipped_of(left: SymbolLink.Skipped) -> Model.Skipped
  return Model.Skipped(file: left.file, diagnostic: DiagnosticModel.of_problem(left.problem))
end

# `alias` is the empty text for an import with a list of names.
def import_of(declaration: Ast.ImportDecl) -> Model.Import
  names = declaration.names.map do |name: Ast.ImportName|
    Model.ImportName(name: name.name, local: name.local, range: DiagnosticModel.range_of(name.span))
  end
  return Model.Import(
    path: declaration.path,
    alias: text(declaration.alias),
    names: names,
    range: DiagnosticModel.range_of(declaration.span),
  )
end

def symbol(match: Symbol.Match) -> Model.Symbol
  type = ""
  payload: List[String] = []
  help = JSON.null()
  signatures: List[String] = []
  case match.extra
    Symbol.Extra.Declared -> type = type
    Symbol.Extra.Field(written) -> type = written
    Symbol.Extra.Variant(types) -> payload = types
    Symbol.Extra.Builtin(entry) ->
      help = CatalogJson.builtin(entry)
      signatures = Builtins.signature(entry).split("\n")
  end
  return Model.Symbol(
    kind: match.kind,
    name: match.name,
    owner: match.owner,
    module: match.file,
    exported: match.exported,
    signature: match.signature,
    doc: text(match.doc),
    range: DiagnosticModel.range_of(match.span),
    name_range: DiagnosticModel.range_of(match.name_span),
    type: type,
    payload: payload,
    help: help,
    signatures: signatures,
  )
end

def definition_of(definition: Ast.Optional[Definitions.Definition], home: String) -> List[Model.Definition]
  case definition
    Ast.Optional.Absent -> return []
    Ast.Optional.Present(found) ->
      return [
        Model.Definition(
          kind: found.kind,
          name: found.name,
          file: home,
          range: DiagnosticModel.range_of(found.span),
          name_range: DiagnosticModel.range_of(found.name_span),
          signature: found.signature,
          doc: text(found.doc),
        ),
      ]
  end
end
