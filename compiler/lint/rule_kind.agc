## LINT-ERROR-KIND: an `is_a?` or `kind_of?` literal whose first segment is a family of the builtin kinds (ERROR_KINDS)
## but which names neither the family nor one of its kinds. A typo there makes the branch never match, and nothing
## else tells. A family of a library's own (`db.*`) and a computed kind are left alone: a library may add kinds, the
## builtins and std/ only those of the table.

import {ERROR_KINDS} from "../catalog/builtins"
import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Suggest from "../syntax/suggest"
import Rules from "rules"

METHODS = Set.new(["is_a?", "kind_of?"])
QUALIFIED = Set.new(["Error.is_a?", "Error.kind_of?"])

# Every name that is_a? takes in a builtin family: each kind and each dotted prefix of one, so the family itself.
KNOWN = Set.new(
  ERROR_KINDS.flat_map do |kind: String|
    (1..kind.split(".").size).to_a.map do |count: Int| kind.split(".").take(count).join(".") end
  end,
)
FAMILIES = Set.new(ERROR_KINDS.map do |kind: String| kind.split(".")[0] end)

## The suggestion for an is_a? or kind_of? call: `e.is_a?("x")`, `Error.is_a?(e, "x")` or `e |> is_a?("x")`. A bare
## `is_a?(e, "x")` that is not piped, or one in a file that defines `is_a?` or `kind_of?` itself (`functions`), is a
## function of the program, not the method of Error.
export def suggestions(file: String, expr: Ast.Expr, functions: Set[String]) -> List[Problems.Problem]
  case expr
    Ast.Expr.MethodCall(node) ->
      return [] if !METHODS.include?(node.name) or functions.include?(node.name) or node.args.size != 1

      literal(file, node.args[0])
    Ast.Expr.Call(node) ->
      bare = METHODS.include?(node.name) and node.piped and !functions.include?(node.name)
      return [] if !(bare or QUALIFIED.include?(node.name)) or node.args.size != 2

      literal(file, node.args[1])
    _ -> []
  end
end

def literal(file: String, arg: Ast.Expr) -> List[Problems.Problem]
  case arg
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Text(kind) ->
          family = kind.split(".")[0]
          return [] if !FAMILIES.include?(family) or KNOWN.include?(kind)

          message = "\"#{kind}\" is not a kind of the builtin #{family} family"
          rule = Rules.ERROR_KIND.with(message: message, help: help(kind, family))
          [Rules.at(file, rule, node.span)]
        _ -> []
      end

    _ -> []
  end
end

# The did-you-mean of the nearest kind of the family, or the list of its kinds when none is near.
def help(kind: String, family: String) -> String
  members = ERROR_KINDS.select do |known: String| known.start_with?("#{family}.") end
  return "#{family} has no dotted kinds: is_a?(\"#{family}\")" if members.size == 0

  case Suggest.did_you_mean(kind, [family].concat(members))
    some(text) -> text
    none -> "the #{family} family has the kinds #{members.join(", ")}; is_a?(\"#{family}\") takes them all"
  end
end
