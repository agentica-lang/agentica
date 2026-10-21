## `agentica refs` as a stage (docs/future/39-semantic-cli.md, 39.3): a linked and checked program and a position in
## its root file in, the declaration of the name there and every reference to it out, or QUERY-NO-EXPRESSION. The
## program is the root file and what it imports, so a use in a file that only imports the root file is not seen.
##
## The name at the position is found as `type-at` finds it: a local by the scopes of query/locals.agc, anything else by
## the places that query/sites.agc lists for the root file, where the position is on the written name or on a
## declaration's own name. The references are the other places of the same target in every module, so two names that
## look alike but are different declarations (a field `name` of two structs, a local of the same name in two blocks)
## never mix.

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
import TypeAt from "type_at"

## One use of the declaration: its `kind` (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`), the
## `function` it is in ("" at the top level), the `file` (of its LinkedModule) and the `span` of the name.
export struct Reference
  kind: String
  function: String
  file: String
  span: Source.Span
end

## What a position names and where it is used. `definition` is Absent for a builtin, which `builtin` names
## (`File.read`; "" for anything else). `owner` is the struct of a field or the enum of a variant, as its file writes
## it ("" for anything else). `references` do not include the definition; they are in the order of the linked files
## and, within one file, of the text.
export struct Answer
  definition: Ast.Optional[Definitions.Definition]
  owner: String
  builtin: String
  references: List[Reference]
end

## The references to what `asked`, a position in the root file of `linked` (checked as `checked`), names, or
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

## Whether the answer needs the types of every function to be complete: a field is read through the type of its target,
## and a builtin may be a method that resolved through one.
export def needs_types?(found: Answer) -> Bool
  case found.definition
    Ast.Optional.Present(declared) -> return declared.kind == "field"
    Ast.Optional.Absent -> return true
  end
end

## The definition of the declaration `target` names, or Absent for a builtin.
export def defined(modules: List[Linker.LinkedModule], target: Sites.Target) -> Ast.Optional[Definitions.Definition]
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
    definition: Ast.Optional.Present(Definitions.of_local(module, local, type)),
    owner: "",
    builtin: "",
    references: once(uses.sort_by do |use: Reference| use.span.start.offset end),
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

# Anything else: the place of the root file that the position is on, and the other places of its target.
def of_name(
  linked: Linker.Linked,
  checked: Checker.Checked,
  asked: Position.Asked,
  offset: Int,
  here: Source.Span,
) -> Diag.Outcome[Answer]
  declared = Sites.declared_names(linked.modules)
  root = linked.modules[0]
  own = Sites.of_module(root, checked, declared, "")
  case innermost(own, offset)
    Ast.Optional.Absent -> return Diag.Outcome.Failed(Position.no_expression(asked, here))
    Ast.Optional.Present(site) ->
      key = site.target.key
      found = used(root, own, key)
      for module in linked.modules.drop(1)
        found = found.concat(used(module, Sites.of_module(module, checked, declared, key), key))
      end
      return Diag.Outcome.Done(named_answer(linked, site.target, found))
  end
end

# The references among the sites of `module`: those of the target `key` that are not its definition.
def used(module: Linker.LinkedModule, sites: List[Sites.Site], key: String) -> List[Reference]
  found = sites.filter do |site: Sites.Site| site.target.key == key and site.kind != "definition" end
  return found.map do |site: Sites.Site|
    Reference(kind: site.kind, function: site.function, file: module.file, span: site.span)
  end
end

def named_answer(linked: Linker.Linked, target: Sites.Target, references: List[Reference]) -> Answer
  definition = defined(linked.modules, target)
  builtin = ""
  case definition
    Ast.Optional.Absent -> builtin = target.name
    Ast.Optional.Present(_) -> builtin = ""
  end
  return Answer(
    definition: definition,
    owner: T.display_name(target.owner),
    builtin: builtin,
    references: references,
  )
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
