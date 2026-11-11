## `agentica refs` as a stage (docs/grammar/06b-builtins.md): a linked and checked program and a position in
## its first file in, the declaration of the name there and every reference to it out, or QUERY-NO-EXPRESSION; or the
## program and a declaration found by name (`of_match`). The program is the files of the command line and what they
## import (Linker.link_programs), so a use in any of them is seen.
##
## The name at the position is found as `type-at` finds it: a local by the scopes of query/locals.agc, an imported name
## by the import lists, anything else by the places that query/sites.agc lists for the first file, where the position
## is on the written name or on a declaration's own name. The references are the other places of the same target in
## every module, so two names that look alike but are different declarations (a field `name` of two structs, a local of
## the same name in two blocks) never mix.

import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Declarations from "../modules/declarations"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import At from "at"
import Definitions from "definitions"
import Locals from "locals"
import Position from "query_position"
import Sites from "sites"
import Symbol from "symbol"
import TypeAt from "type_at"

## One use of the declaration: its `kind` (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`, and
## `qualifier` for the name of a module block written in front of one of its names), the `function` it is in ("" at
## the top level), the `file` (of its LinkedModule) and the `span` of the name.
export struct Reference
  kind: String
  function: String
  file: String
  span: Source.Span
end

## What a position or a name names and where it is used. `definition` is the declaration as `symbol` lists it (`none`
## for a builtin, which `builtin` names: `File.read`; "" for anything else); a local is a match of the kind
## `parameter`, `local`, `loop` or `pattern`. `references` do not include the definition; they are in the order of the
## linked files and, within one file, of the text.
export struct Answer
  definition: Optional[Symbol.Match]
  builtin: String
  references: List[Reference]
end

## The references to what `asked`, a position in the first file of `linked` (checked as `checked`), names, or
## QUERY-NO-EXPRESSION.
export def answer(linked: Linker.Linked, checked: Checker.Checked, asked: Position.Asked) -> Diag.Outcome[Answer]
  case Position.locate(linked.modules[0].text, asked.line, asked.column)
    Position.Located.Outside(span) -> Diag.Outcome.Failed(Position.no_expression(asked, span))
    Position.Located.At(offset) ->
      here = Position.character(offset, asked.line, asked.column)
      focused = At.focus(linked, offset)
      case Locals.find(focused.modules[0], checked.bound, offset)
        some(found) ->
          return Diag.Outcome.Failed(Position.no_expression(asked, here)) if found.local.kind == "discard"

          Diag.Outcome.Done(of_local(focused, checked, found.local))
        none -> of_name(focused, checked, asked, offset, here)
      end
  end
end

## The references to the declaration or builtin that `found` is, a match of `Symbol.answer` over the modules of
## `linked` (checked as `checked`). A builtin has no definition: `builtin` names it.
export def of_match(linked: Linker.Linked, checked: Checker.Checked, found: Symbol.Match) -> Answer
  return of_block(linked, checked, found) if found.kind == "module"

  defined = some(found)
  if found.kind == "builtin"
    defined = none
  end

  of_target(linked, checked, target_of(linked.modules, found), defined)
end

## Whether the answer needs the types of every function to be complete: a field is read through the type of its target,
## and a builtin may be a method that resolved through one.
export def needs_types?(found: Answer) -> Bool
  case found.definition
    some(declared) -> declared.kind == "field"
    none -> true
  end
end

## The definition of the declaration `target` names, or `none` for a builtin.
export def definition_of(modules: List[Linker.LinkedModule], target: Sites.Target) -> Optional[Definitions.Definition]
  if target.kind == "field"
    return Definitions.of_field(modules, target.owner, target.name)
  elsif target.kind == "variant"
    return Definitions.of_variant(modules, target.owner, target.name)
  end

  Definitions.of_name(modules, target.name)
end

# A local: its binding is the definition, and its uses are in the function that holds it.
def of_local(linked: Linker.Linked, checked: Checker.Checked, local: Locals.Local) -> Answer
  module = linked.modules[0]
  type = T.to_text_as(local.type, TypeAt.written_prefixes(linked))
  function = function_at(module, local.name_span.start.offset)
  uses = Locals.uses(module, checked.bound, local).map do |span: Source.Span|
    Reference(kind: "binding", function: function, file: module.file, span: span)
  end

  Answer(
    definition: some(of_definition(Linker.home_key(module), Definitions.of_local(module, local, type))),
    builtin: "",
    references: once(uses.sort_by do |use: Reference| use.span.start.offset end),
  )
end

# The match of a local: it has no `exported` flag, no doc and nothing but its signature (`name: Type`).
def of_definition(file: String, found: Definitions.Definition) -> Symbol.Match
  Symbol.Match(
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

  out
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
    some(target) -> return Diag.Outcome.Done(of_target(linked, checked, target, none))
    none -> declared = declared
  end

  own = Sites.of_module(root, checked, declared, "")
  case Sites.innermost(own, offset)
    none ->
      case block_at(linked, offset)
        some(block) -> Diag.Outcome.Done(of_block(linked, checked, block))
        none -> Diag.Outcome.Failed(Position.no_expression(asked, here))
      end

    some(site) ->
      key = site.target.key
      found = used(root, own, key)
      for module in linked.modules.drop(1)
        found = found.concat(used(module, Sites.of_module(module, checked, declared, key), key))
      end

      Diag.Outcome.Done(named_answer(linked, site.target, none, in_order(linked.modules, found)))
  end
end

# The target that a match stands for: the linked name of the declaration, of its struct or its enum for a member.
def target_of(modules: List[Linker.LinkedModule], found: Symbol.Match) -> Sites.Target
  return Sites.named(found.name) if found.kind == "builtin"

  # The file of a match is the file of a module block too: the block is the module whose span holds the name.
  same = modules.filter do |module: Linker.LinkedModule| Linker.home_key(module) == found.file end
  prefix = At.holder(same, found.name_span.start.offset).prefix
  if found.kind == "field" or found.kind == "variant"
    return Sites.member(found.kind, "#{prefix}#{found.owner}", found.name)
  end

  Sites.named("#{prefix}#{found.name}")
end

# The uses of `target` in every module. `defined` is its definition when the caller has it.
def of_target(
  linked: Linker.Linked,
  checked: Checker.Checked,
  target: Sites.Target,
  defined: Optional[Symbol.Match],
) -> Answer
  declared = Sites.declared_names(linked.modules)
  found: List[Reference] = []
  for module in linked.modules
    found = found.concat(used(module, Sites.of_module(module, checked, declared, target.key), target.key))
  end

  named_answer(linked, target, defined, in_order(linked.modules, found))
end

# The references in the order of the files of `modules` and, within one file, of the text: a file and its module blocks
# are several modules, which other files may come between.
def in_order(modules: List[Linker.LinkedModule], found: List[Reference]) -> List[Reference]
  out: List[Reference] = []
  files = modules.map do |module: Linker.LinkedModule| module.file end
  for file in files.uniq
    here = found.filter do |use: Reference| use.file == file end
    out = out.concat(here.sort_by do |use: Reference| use.span.start.offset end)
  end

  out
end

# The module block whose name the root file writes at `offset` (`Counter` of `module Counter`), as `symbol` lists it.
def block_at(linked: Linker.Linked, offset: Int) -> Optional[Symbol.Match]
  root = Linker.home_key(linked.modules[0])
  for file in linked.modules
    next if file.key != root

    for declaration in file.parsed.declarations
      case Declarations.unwrap(declaration)
        Ast.Decl.Module(node) -> return Symbol.declared_at(file, node.name_span) if At.holds?(node.name_span, offset)
        _ -> next
      end
    end
  end

  none
end

# A module block, `found`: the places that write its name in front of one of its own names (`Counter` of
# `Counter.start(1)` and of `Agents.Counter.State`), kind `qualifier`, read from the sites of its declarations. A name
# that the block writes bare and an import list that names the block are not references to it.
def of_block(linked: Linker.Linked, checked: Checker.Checked, found: Symbol.Match) -> Answer
  blocks = linked.modules.filter do |module: Linker.LinkedModule|
    Linker.home_key(module) == found.file and module.block == found.name
  end

  uses: List[Reference] = []
  if blocks.size > 0
    declared = Sites.declared_names(linked.modules)
    for module in linked.modules
      for site in Sites.of_module(module, checked, declared, "")
        case qualifier(module.text, site, blocks[0].prefix)
          some(span) ->
            uses = uses.push(Reference(kind: "qualifier", function: site.function, file: module.file, span: span))
          none -> next
        end
      end
    end
  end

  Answer(definition: some(found), builtin: "", references: in_order(linked.modules, uses))
end

# The part written just before the name of `site` (`Counter` of `Agents.Counter.start`) when the site names a top-level
# declaration of the block with `prefix`, or `none`. A variant needs no case of its own: its enum is a site that
# reaches from the first part (`Counter.Msg` of `Counter.Msg.Add`).
def qualifier(text: String, site: Sites.Site, prefix: String) -> Optional[Source.Span]
  # A definition is never qualified: its reach is the bare name.
  return none if site.target.kind != "name" or !site.target.name.start_with?(prefix)

  reach = site.reach
  written = text.slice(reach.start.offset, reach.stop.offset - reach.start.offset)
  parts = written.split("(")[0].split("[")[0].split(".")
  return none if parts.size < 2

  index = parts.size - 2
  name = parts[index]
  skip = 0
  if index > 0
    skip = parts.take(index).join(".").length + 1
  end

  return none if name == "" or name.strip != name or written.slice(0, skip).include?("\n")

  start = Source.Position(offset: reach.start.offset + skip, line: reach.start.line, column: reach.start.column + skip)
  stop = Source.Position(offset: start.offset + name.length, line: start.line, column: start.column + name.length)
  some(Source.Span(start: start, stop: stop))
end

# The references among the sites of `module`: those of the target `key` that are not its definition.
def used(module: Linker.LinkedModule, sites: List[Sites.Site], key: String) -> List[Reference]
  found = sites.filter do |site: Sites.Site| site.target.key == key and site.kind != "definition" end
  found.map do |site: Sites.Site|
    Reference(kind: site.kind, function: site.function, file: module.file, span: site.span)
  end
end

# The answer for `target`; its definition is `given`, or is looked up in the modules.
def named_answer(
  linked: Linker.Linked,
  target: Sites.Target,
  given: Optional[Symbol.Match],
  references: List[Reference],
) -> Answer
  definition = given
  case given
    none -> definition = defined(linked.modules, target)
    some(_) -> definition = given
  end

  builtin = ""
  case definition
    none -> builtin = target.name
    some(_) -> builtin = ""
  end

  Answer(definition: definition, builtin: builtin, references: references)
end

# The declaration of `target` as `symbol` lists it; `none` for a builtin.
def defined(modules: List[Linker.LinkedModule], target: Sites.Target) -> Optional[Symbol.Match]
  case definition_of(modules, target)
    none -> none
    some(declared) ->
      same = modules.filter do |module: Linker.LinkedModule| module.file == declared.file end
      Symbol.declared_at(At.holder(same, declared.name_span.start.offset), declared.name_span)
  end
end

# The name of the function that holds `offset`; "" at the top level.
def function_at(module: Linker.LinkedModule, offset: Int) -> String
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        return T.display_name(node.name) if node.span.start.offset <= offset and offset < node.span.stop.offset

      _ -> next
    end
  end

  ""
end
