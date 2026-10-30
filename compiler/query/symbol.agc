## `agentica symbol NAME [PATH...]` as a stage (docs/future/39-semantic-cli.md, 39.3 and 39.4): where a name is
## defined, in every module linked from the files of `PATH...`, or QUERY-NOT-FOUND. The declarations, private ones too,
## are the items of `agentica doc` (docs/doc_model.agc), read from the file as the parser gave it, so a match has the
## signature, the `##` doc and the spans that `outline` and `type-at` give. A name is written as the code writes it:
## `total`, `User.email`, `Option.Some`, through the alias a root file imports the module under (`Models.User`),
## through `std/MOD.` for a module of the standard library, or as a builtin (`Map.get`, `puts`). Linking is in
## symbol_link.agc. `agentica refs NAME` takes its name from `search`, so the two commands resolve a name alike.

import BuiltinModel from "../catalog/builtin_model"
import {PUBLIC_NAMES, form_signature} from "../catalog/builtins"
import CatalogJson from "../catalog/catalog_json"
import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Model from "../docs/doc_model"
import Signature from "../docs/signature"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Modules from "../modules/modules"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Suggest from "../syntax/suggest"
import QueryOptions from "query_options"
import SymbolLink from "symbol_link"
import SymbolPaths from "symbol_paths"

## What a match has besides the common data: the type of a field, the payload of a variant, the catalog row of a
## builtin.
export enum Extra
  Declared
  Field(String)
  Variant(List[String])
  Builtin(BuiltinModel.Builtin)
end

## One declaration found. `kind` is `function`, `struct`, `enum`, `alias`, `constant`, `field`, `variant` or `builtin`.
## `name` is the name alone (`email`), `owner` the struct or enum of a field or a variant ("" otherwise). `file` is the
## key of the module (`display` of query_files.agc names it in an answer), "" for a builtin, which has no place; so
## do its spans. `exported` is the flag of the declaration, or of the struct or enum of a member. `signature` and `doc`
## are the ones `type-at` gives the definition.
export struct Match
  kind: String
  name: String
  owner: String
  file: String
  exported: Bool
  signature: String
  doc: Optional[String]
  span: Source.Span
  name_span: Source.Span
  extra: Extra
end

## The matches, in the order the modules were linked and then in source order (the builtin last), and the roots that
## were left out.
export struct Answer
  matches: List[Match]
  skipped: List[SymbolLink.Skipped]
end

## The answer, or why there is none.
export enum Outcome
  Found(Answer)
  Refused(Problems.Problem)
end

## The matches of `name` in the modules linked from `roots`. When every root is left out there is nothing to search:
## the answer is the first problem of the first one (an error of the program, exit status 1). A name that nothing
## declares is QUERY-NOT-FOUND.
export def answer(
  name: String,
  roots: List[SymbolPaths.Root],
  settings: Env.Settings,
  parses: Modules.Parses,
) -> Outcome
  return search(name, roots, SymbolLink.link(roots, settings, parses))
end

## The matches of `name` in `linked`, the program of `roots` (symbol_link.agc): as `answer`, for a caller that needs
## the program as well.
export def search(name: String, roots: List[SymbolPaths.Root], linked: SymbolLink.Linked) -> Outcome
  if linked.modules.size == 0
    return Outcome.Refused(linked.skipped[0].problem)
  end

  aliases = aliases_of(linked.modules, roots)
  matches = declared(linked.modules, aliases, name).concat(builtin(name))
  if matches.size == 0
    return Outcome.Refused(not_found(name, linked))
  end

  return Outcome.Found(Answer(matches: matches, skipped: linked.skipped))
end

## The declaration of `module` whose name is written at `name_span`: a top-level declaration, a field or a variant, as
## `answer` lists it (the `file` is the key of the module). `none` when the span is no declaration's name.
export def declared_at(module: Linker.LinkedModule, name_span: Source.Span) -> Optional[Match]
  at = name_span.start.offset
  for item in Model.declared(module.parsed, module.text)
    if item.name_span.start.offset == at
      return some(item_match(module.key, item))
    end

    case item.detail
      Model.Detail.Struct(fields) ->
        for field in fields
          if field.name_span.start.offset == at
            return some(field_match(module.key, item, field))
          end
        end

      Model.Detail.Enum(variants) ->
        for variant in variants
          if variant.name_span.start.offset == at
            return some(variant_match(module.key, item, variant))
          end
        end

      Model.Detail.Function(_, _) -> next
      Model.Detail.Plain -> next
    end
  end

  return none
end

# The aliases that the files of the roots import each module under, by the key of the module. The same alias can name
# different modules in different files, so a name through it lists a match for each.
def aliases_of(modules: List[Linker.LinkedModule], roots: List[SymbolPaths.Root]) -> Map[String, List[String]]
  by_key: Map[String, List[String]] = {}
  for module in modules
    if roots.any? do |root: SymbolPaths.Root| root.key == module.key end
      for alias in module.aliases.keys.sort
        target = module.aliases[alias]
        by_key = by_key.put(target, aliases_for(by_key, target).push(alias))
      end
    end
  end

  return by_key
end

# The aliases that the roots import the module `key` under, in the order they were found.
def aliases_for(aliases: Map[String, List[String]], key: String) -> List[String]
  found = aliases.get(key)
  if found.some?
    return found.unwrap!
  end

  return []
end

def declared(
  modules: List[Linker.LinkedModule],
  aliases: Map[String, List[String]],
  name: String,
) -> List[Match]
  found: List[Match] = []
  for module in modules
    for item in Model.declared(module.parsed, module.text)
      for written in written_names(module, item.exported, aliases)
        found = found.concat(of_item(module.key, item, written, name))
      end
    end
  end

  return found
end

# The beginnings a name of a declaration can have: none (the name as the file declares it), and for an exported one the
# alias of a root file (`Models.`) and `std/NAME.` for a module of the standard library.
def written_names(module: Linker.LinkedModule, exported: Bool, aliases: Map[String, List[String]]) -> List[String]
  out = [""]
  if !exported
    return out
  end

  for alias in aliases_for(aliases, module.key).uniq
    out = out.push("#{alias}.")
  end

  if module.key.starts_with?("std/") and module.key.ends_with?(".agc")
    out = out.push("#{module.key.slice(0, module.key.length - 4)}.")
  end

  return out
end

# The item, or its field or variant, that `name` names when the item is written `prefix` + its name.
def of_item(file: String, item: Model.Item, prefix: String, name: String) -> List[Match]
  written = "#{prefix}#{item.name}"
  if written == name
    return [item_match(file, item)]
  elsif !name.starts_with?("#{written}.")
    return []
  end

  member = name.slice(written.length + 1, name.length - written.length - 1)
  case item.detail
    Model.Detail.Struct(fields) ->
      return fields.filter do |field: Model.Field| field.name == member end.map do |field: Model.Field|
        field_match(file, item, field)
      end

    Model.Detail.Enum(variants) ->
      return variants.filter do |variant: Model.Variant| variant.name == member end.map do |variant: Model.Variant|
        variant_match(file, item, variant)
      end

    Model.Detail.Function(_, _) -> return []
    Model.Detail.Plain -> return []
  end
end

def item_match(file: String, item: Model.Item) -> Match
  return Match(
    kind: item.kind,
    name: item.name,
    owner: "",
    file: file,
    exported: item.exported,
    signature: item.signature,
    doc: item.doc,
    span: item.span,
    name_span: item.name_span,
    extra: Extra.Declared,
  )
end

def field_match(file: String, item: Model.Item, field: Model.Field) -> Match
  return Match(
    kind: "field",
    name: field.name,
    owner: item.name,
    file: file,
    exported: item.exported,
    signature: "#{field.name}: #{field.type}",
    doc: field.doc,
    span: field.span,
    name_span: field.name_span,
    extra: Extra.Field(field.type),
  )
end

def variant_match(file: String, item: Model.Item, variant: Model.Variant) -> Match
  return Match(
    kind: "variant",
    name: variant.name,
    owner: item.name,
    file: file,
    exported: item.exported,
    signature: Signature.variant_text(variant.name, variant.payload),
    doc: variant.doc,
    span: variant.span,
    name_span: variant.name_span,
    extra: Extra.Variant(variant.payload),
  )
end

# The public builtin called `name`, as `agentica help NAME` finds it: a match with no file and no place.
def builtin(name: String) -> List[Match]
  entry = CatalogJson.public(name)
  if !entry.ok?
    return []
  end

  here = Source.Position(offset: 0, line: 0, column: 0)
  nowhere = Source.Span(start: here, stop: here)
  return [
    Match(
      kind: "builtin",
      name: entry.unwrap!.name,
      owner: "",
      file: "",
      exported: true,
      signature: form_signature(entry.unwrap!),
      doc: none,
      span: nowhere,
      name_span: nowhere,
      extra: Extra.Builtin(entry.unwrap!),
    ),
  ]
end

# QUERY-NOT-FOUND, with the closest name as the help, and the roots that were left out: the name may be in one.
def not_found(name: String, linked: SymbolLink.Linked) -> Problems.Problem
  hints: List[String] = []
  case Suggest.did_you_mean(name, candidates(linked.modules).concat(PUBLIC_NAMES))
    some(text) -> hints = hints.push(text)
    none -> hints = hints
  end

  if linked.skipped.size > 0
    files = linked.skipped.map do |skipped: SymbolLink.Skipped| skipped.file end
    hints = hints.push("not searched: #{files.join(", ")}")
  end

  help = Diag.Help.NoHelp
  if hints.size > 0
    help = Diag.Help.Hint(hints.join("; "))
  end

  return QueryOptions.at_arguments("QUERY-NOT-FOUND", "#{name} is not declared in the linked files", help)
end

# Every name a query can write for a declaration, as the file declares it: `total`, `User.email`, `Option.Some`.
def candidates(modules: List[Linker.LinkedModule]) -> List[String]
  names: List[String] = []
  for module in modules
    for item in Model.declared(module.parsed, module.text)
      names = names.push(item.name)
      case item.detail
        Model.Detail.Struct(fields) ->
          names = names.concat(fields.map do |field: Model.Field| "#{item.name}.#{field.name}" end)
        Model.Detail.Enum(variants) ->
          names = names.concat(variants.map do |variant: Model.Variant| "#{item.name}.#{variant.name}" end)
        Model.Detail.Function(_, _) -> names = names
        Model.Detail.Plain -> names = names
      end
    end
  end

  return names
end
