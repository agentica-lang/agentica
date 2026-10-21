## `agentica refs` as a stage (docs/future/39-semantic-cli.md, 39.3): a linked and checked program and a position in
## its first file in, the declaration of the name there and every reference to it out, or QUERY-NO-EXPRESSION; or the
## program and a declaration found by name (`of_match`). The program is the files of the command line and what they
## import (Linker.link_programs), so a use in any of them is seen.
##
## The name at the position is found as `type-at` finds it: a local by the scopes of query/locals.agc, an imported name
## by the import lists, anything else by the places that query/sites.agc lists for the first file, where the position
## is on the written name or on a declaration's own name. The references are the other places of the same target in
## every module, so two names that look alike but are different declarations (a field `name` of two structs, a local of
## the same name in two blocks) never mix.

import Ast from "../syntax/ast"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Linker from "../modules/linker"
import Source from "../syntax/source"
import T from "../syntax/types"
import Definitions from "definitions"
import Locals from "locals"
import Position from "query_position"
import Sites from "sites"
import Symbol from "symbol"
import TypeAt from "type_at"

## One use of the declaration: its `kind` (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`), the
## `function` it is in ("" at the top level), the `file` (of its LinkedModule) and the `span` of the name.
export struct Reference
  kind: String
  function: String
  file: String
  span: Source.Span
end

## What a position or a name names and where it is used. `definition` is the declaration as `symbol` lists it (Absent
## for a builtin, which `builtin` names: `File.read`; "" for anything else); a local is a match of the kind
## `parameter`, `local`, `loop` or `pattern`. `references` do not include the definition; they are in the order of the
## linked files and, within one file, of the text.
export struct Answer
  definition: Ast.Optional[Symbol.Match]
  builtin: String
  references: List[Reference]
end

## The references to what `asked`, a position in the first file of `linked` (checked as `checked`), names, or
## QUERY-NO-EXPRESSION.
export def answer(linked: Linker.Linked, checked: Checker.Checked, asked: Position.Asked) -> Diag.Outcome[Answer]
  module = linked.modules[0]
  case Position.locate(module.text, asked.line, asked.column)
    Position.Located.Outside(span) -> return Diag.Outcome.Failed(Position.no_expression(asked, span))
    Position.Located.At(offset) ->
      here = Position.character(offset, asked.line, asked.column)
      case Locals.find(module, checked.bound, offset)
        Ast.Optional.Present(found) ->
          if found.local.kind == "discard"
            return Diag.Outcome.Failed(Position.no_expression(asked, here))
          end
          return Diag.Outcome.Done(of_local(linked, checked, found.local))
        Ast.Optional.Absent -> return of_name(linked, checked, asked, offset, here)
      end
  end
end

## The references to the declaration or builtin that `found` is, a match of `Symbol.answer` over the modules of
## `linked` (checked as `checked`). A builtin has no definition: `builtin` names it.
export def of_match(linked: Linker.Linked, checked: Checker.Checked, found: Symbol.Match) -> Answer
  defined = Ast.Optional.Present(found)
  if found.kind == "builtin"
    defined = Ast.Optional.Absent
  end
  return of_target(linked, checked, target_of(linked.modules, found), defined)
end

## Whether the answer needs the types of every function to be complete: a field is read through the type of its target,
## and a builtin may be a method that resolved through one.
export def needs_types?(found: Answer) -> Bool
  case found.definition
    Ast.Optional.Present(declared) -> return declared.kind == "field"
    Ast.Optional.Absent -> return true
  end
end

## The definition of the declaration `target` names, or Absent for a builtin.
export def definition_of(
  modules: List[Linker.LinkedModule],
  target: Sites.Target,
) -> Ast.Optional[Definitions.Definition]
  if target.kind == "field"
    return Definitions.of_field(modules, target.owner, target.name)
  elsif target.kind == "variant"
    return Definitions.of_variant(modules, target.owner, target.name)
  end
  return Definitions.of_name(modules, target.name)
end

## The innermost site whose written name holds the character at `offset`: the shortest, and the first of two equal.
export def innermost(sites: List[Sites.Site], offset: Int) -> Ast.Optional[Sites.Site]
  best: Ast.Optional[Sites.Site] = Ast.Optional.Absent
  best_size = -1
  for site in sites
    size = site.reach.stop.offset - site.reach.start.offset
    closer = best_size < 0 or size < best_size
    if closer and site.reach.start.offset <= offset and offset < site.reach.stop.offset
      best = Ast.Optional.Present(site)
      best_size = size
    end
  end
  return best
end

# A local: its binding is the definition, and its uses are in the function that holds it.
def of_local(linked: Linker.Linked, checked: Checker.Checked, local: Locals.Local) -> Answer
  module = linked.modules[0]
  type = T.to_text_as(local.type, TypeAt.written_prefixes(linked))
  function = function_at(module, local.name_span.start.offset)
  uses = Locals.uses(module, checked.bound, local).map do |span: Source.Span|
    Reference(kind: "binding", function: function, file: module.file, span: span)
  end
  return Answer(
    definition: Ast.Optional.Present(of_definition(module.key, Definitions.of_local(module, local, type))),
    builtin: "",
    references: once(uses.sort_by do |use: Reference| use.span.start.offset end),
  )
end

# The match of a local: it has no `exported` flag, no doc and nothing but its signature (`name: Type`).
def of_definition(file: String, found: Definitions.Definition) -> Symbol.Match
  return Symbol.Match(
    kind: found.kind,
    name: found.name,
    owner: "",
    file: file,
    exported: false,
    signature: found.signature,
    doc: found.doc,
    span: found.span,
    name_span: found.name_span,
    extra: Symbol.Extra.Declared,
  )
end

# `x += 1` is the assignment to `x` and the read of `x` at one place: it is one reference.
def once(sorted: List[Reference]) -> List[Reference]
  out: List[Reference] = []
  for found in sorted
    if out.size == 0 or out[out.size - 1].span.start.offset != found.span.start.offset
      out = out.push(found)
    end
  end
  return out
end

# Anything else: the name of an import list or the place of the first file that the position is on, and the other
# places of its target.
def of_name(
  linked: Linker.Linked,
  checked: Checker.Checked,
  asked: Position.Asked,
  offset: Int,
  here: Source.Span,
) -> Diag.Outcome[Answer]
  declared = Sites.declared_names(linked.modules)
  root = linked.modules[0]
  case Sites.imported(root, offset)
    Ast.Optional.Present(target) -> return Diag.Outcome.Done(of_target(linked, checked, target, Ast.Optional.Absent))
    Ast.Optional.Absent -> declared = declared
  end
  own = Sites.of_module(root, checked, declared, "")
  case innermost(own, offset)
    Ast.Optional.Absent -> return Diag.Outcome.Failed(Position.no_expression(asked, here))
    Ast.Optional.Present(site) ->
      key = site.target.key
      found = used(root, own, key)
      for module in linked.modules.drop(1)
        found = found.concat(used(module, Sites.of_module(module, checked, declared, key), key))
      end
      return Diag.Outcome.Done(named_answer(linked, site.target, Ast.Optional.Absent, found))
  end
end

# The target that a match stands for: the linked name of the declaration, of its struct or its enum for a member.
def target_of(modules: List[Linker.LinkedModule], found: Symbol.Match) -> Sites.Target
  if found.kind == "builtin"
    return Sites.named(found.name)
  end
  home = modules.filter do |module: Linker.LinkedModule| module.key == found.file end
  prefix = home[0].prefix
  if found.kind == "field" or found.kind == "variant"
    return Sites.member(found.kind, "#{prefix}#{found.owner}", found.name)
  end
  return Sites.named("#{prefix}#{found.name}")
end

# The uses of `target` in every module. `defined` is its definition when the caller has it.
def of_target(
  linked: Linker.Linked,
  checked: Checker.Checked,
  target: Sites.Target,
  defined: Ast.Optional[Symbol.Match],
) -> Answer
  declared = Sites.declared_names(linked.modules)
  found: List[Reference] = []
  for module in linked.modules
    found = found.concat(used(module, Sites.of_module(module, checked, declared, target.key), target.key))
  end
  return named_answer(linked, target, defined, found)
end

# The references among the sites of `module`: those of the target `key` that are not its definition.
def used(module: Linker.LinkedModule, sites: List[Sites.Site], key: String) -> List[Reference]
  found = sites.filter do |site: Sites.Site| site.target.key == key and site.kind != "definition" end
  return found.map do |site: Sites.Site|
    Reference(kind: site.kind, function: site.function, file: module.file, span: site.span)
  end
end

# The answer for `target`; its definition is `given`, or is looked up in the modules.
def named_answer(
  linked: Linker.Linked,
  target: Sites.Target,
  given: Ast.Optional[Symbol.Match],
  references: List[Reference],
) -> Answer
  definition = given
  case given
    Ast.Optional.Absent -> definition = defined(linked.modules, target)
    Ast.Optional.Present(_) -> definition = given
  end
  builtin = ""
  case definition
    Ast.Optional.Absent -> builtin = target.name
    Ast.Optional.Present(_) -> builtin = ""
  end
  return Answer(definition: definition, builtin: builtin, references: references)
end

# The declaration of `target` as `symbol` lists it; Absent for a builtin.
def defined(modules: List[Linker.LinkedModule], target: Sites.Target) -> Ast.Optional[Symbol.Match]
  case definition_of(modules, target)
    Ast.Optional.Absent -> return Ast.Optional.Absent
    Ast.Optional.Present(declared) ->
      home = modules.filter do |module: Linker.LinkedModule| module.file == declared.file end
      return Symbol.declared_at(home[0], declared.name_span)
  end
end

# The name of the function that holds `offset`; "" at the top level.
def function_at(module: Linker.LinkedModule, offset: Int) -> String
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        if node.span.start.offset <= offset and offset < node.span.stop.offset
          return T.display_name(node.name)
        end
      _ -> next
    end
  end
  return ""
end
