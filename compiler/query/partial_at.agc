## `agentica type-at --partial` for a program that does not check (docs/future/39-semantic-cli.md, 39.6). Where the
## position is on an expression that checking typed, the answer is the one of `type-at`. Where it is not, such as a
## name in a function that failed to check, the answer comes from the link alone: the written name of a function, a
## type, a variant, a constant or a builtin, with its definition and no type. A position that neither knows is
## QUERY-NO-EXPRESSION, as in `type-at`.

import Ast from "../syntax/ast"
import CatalogJson from "../catalog/catalog_json"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Linker from "../modules/linker"
import Model from "../catalog/builtin_model"
import Definitions from "definitions"
import Position from "query_position"
import Refs from "refs"
import Sites from "sites"
import TypeAt from "type_at"

# The sites that a name written in an expression gives. A `read` needs the type of its target and a `definition` is the
# name where a declaration is written, which `type-at` does not answer.
LINKED_KINDS = Set.new(["call", "value", "construct", "type", "pattern"])

## The answer for `asked`, a position in the root file of `linked`, of which `checked` holds the functions that passed.
export def answer(
  linked: Linker.Linked,
  checked: Checker.Checked,
  asked: Position.Asked,
) -> Diag.Outcome[TypeAt.Answer]
  typed = TypeAt.answer(linked, checked, asked)
  case typed
    Diag.Outcome.Done(_) -> return typed
    Diag.Outcome.Failed(_) ->
      module = linked.modules[0]
      case Position.locate(module.text, asked.line, asked.column)
        Position.Located.Outside(_) -> return typed
        Position.Located.At(offset) -> return named(linked, checked, offset, typed)
      end
  end
end

# The answer for the written name at `offset`, or `missed` when no name is written there.
def named(
  linked: Linker.Linked,
  checked: Checker.Checked,
  offset: Int,
  missed: Diag.Outcome[TypeAt.Answer],
) -> Diag.Outcome[TypeAt.Answer]
  module = linked.modules[0]
  sites = Sites.of_module(module, checked, Sites.declared_names(linked.modules), "").filter do |site: Sites.Site|
    LINKED_KINDS.include?(site.kind)
  end
  case Refs.innermost(sites, offset)
    Ast.Optional.Absent -> return missed
    Ast.Optional.Present(site) ->
      definition = Refs.defined(linked.modules, site.target)
      return Diag.Outcome.Done(
        TypeAt.Answer(
          kind: kind_of(definition, site),
          span: site.reach,
          text: module.text.slice(site.reach.start.offset, site.reach.stop.offset - site.reach.start.offset),
          type: "",
          definition: definition,
          builtin: builtin_of(definition, site),
        ),
      )
  end
end

# `builtin` for a name that no file declares and the catalog knows, else `name`.
def kind_of(definition: Ast.Optional[Definitions.Definition], site: Sites.Site) -> String
  case builtin_of(definition, site)
    Ast.Optional.Present(_) -> return "builtin"
    Ast.Optional.Absent -> return "name"
  end
end

def builtin_of(definition: Ast.Optional[Definitions.Definition], site: Sites.Site) -> Ast.Optional[Model.Builtin]
  case definition
    Ast.Optional.Present(_) -> return Ast.Optional.Absent
    Ast.Optional.Absent ->
      entry = CatalogJson.public(site.target.name)
      if entry.ok?
        return Ast.Optional.Present(entry.unwrap!)
      end
      return Ast.Optional.Absent
  end
end
