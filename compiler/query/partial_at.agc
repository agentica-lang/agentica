## `agentica type-at --partial` for a program that does not check (docs/future/39-semantic-cli.md, 39.6). Where the
## position is on an expression that checking typed, the answer is the one of `type-at`. Where it is not, such as a
## name in a function that failed to check, the answer comes from the link alone: the written name of a function, a
## type, a variant, a constant or a builtin, with its definition and no type. A position on a token of such a function
## that the link cannot name is unclear (the program's first problem); any other position that nothing answers is
## QUERY-NO-EXPRESSION, as in `type-at`.

import Model from "../catalog/builtin_model"
import CatalogJson from "../catalog/catalog_json"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import At from "at"
import Definitions from "definitions"
import Position from "query_position"
import Refs from "refs"
import Sites from "sites"
import TypeAt from "type_at"

# The sites that a name written in an expression gives. A `read` needs the type of its target and a `definition` is the
# name where a declaration is written, which `type-at` does not answer. A `type` is not here: `TypeAt.answer` finds the
# name of a type from the link alone, in a function that failed too.
LINKED_KINDS = Set.new(["call", "value", "construct", "pattern"])

## The answer for `asked`, a position in the root file of `linked`, of which `checked` holds the functions that passed
## and `failed` names (by linked name) those that did not. Only a position inside a failed function falls back to the
## link: elsewhere the answer, QUERY-NO-EXPRESSION included, is the one of `type-at`.
export def answer(
  linked: Linker.Linked,
  checked: Checker.Checked,
  failed: List[String],
  asked: Position.Asked,
) -> Diag.Outcome[TypeAt.Answer]
  typed = TypeAt.answer(linked, checked, asked)
  case typed
    Diag.Outcome.Done(_) -> return typed
    Diag.Outcome.Failed(_) ->
      case Position.locate(linked.modules[0].text, asked.line, asked.column)
        Position.Located.Outside(_) -> return typed
        Position.Located.At(offset) ->
          if !in_failed?(linked, failed, offset)
            return typed
          end
          return named(linked, checked, offset, typed)
      end
  end
end

## Whether a position that no answer was found for may still name something: it is on a token inside a function that
## did not check, where only the types are missing. A position anywhere else, such as a blank, a comment, an import
## line or a keyword outside the failed functions, is on no expression, as `type-at` would say of the whole program.
export def unclear?(linked: Linker.Linked, failed: List[String], asked: Position.Asked) -> Bool
  module = linked.modules[0]
  case Position.locate(module.text, asked.line, asked.column)
    Position.Located.Outside(_) -> return false
    Position.Located.At(offset) -> return in_failed?(linked, failed, offset) and TypeAt.on_token?(module.text, offset)
  end
end

# Whether `offset` is in a function of the root file that did not check.
def in_failed?(linked: Linker.Linked, failed: List[String], offset: Int) -> Bool
  for declaration in linked.modules[0].declarations
    case declaration
      Ast.Decl.Function(node) ->
        if At.holds?(node.span, offset) and failed.any? do |name: String| name == node.name end
          return true
        end
      _ -> next
    end
  end
  return false
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
  case Sites.innermost(sites, offset)
    Ast.Optional.Absent -> return missed
    Ast.Optional.Present(site) ->
      definition = Refs.definition_of(linked.modules, site.target)
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
