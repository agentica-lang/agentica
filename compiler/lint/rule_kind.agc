## LINT-ERROR-KIND: an `is_a?` or `kind_of?` literal whose first segment is a family of the builtin kinds (ERROR_KINDS)
## but which names neither the family nor one of its kinds, nor a kind that the file creates with `kind:`. A typo there
## makes the branch never match, and nothing else tells. A family of a library's own (`db.*`) and a computed kind are
## left alone. Lint parses one file, so a kind that an imported module creates is not seen.

import {ERROR_KINDS} from "../catalog/builtins"
import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Suggest from "../syntax/suggest"
import Rules from "rules"

## A kind literal of the file: one that an is_a? or kind_of? call tests (`created` false), or one that a `kind:`
## argument gives (`error("x", kind: "number.negative")`, `e.with(kind: ...)`), which the program creates.
struct Seen
  kind: String
  span: Source.Span
  created: Bool
end

## The kind literals of one expression: the `kind:` arguments of a call or a method call, and the literal an is_a?
## call tests, as `e.is_a?("x")`, `Error.is_a?(e, "x")` or `e |> is_a?("x")`, positional or named `family:`. A bare
## `is_a?(e, "x")` that is not piped, or a piped one in a file that defines `is_a?` or `kind_of?` itself
## (`functions`), is a function of the program; the method form always reaches Error.
def seen(expr: Ast.Expr, functions: Set[String]) -> List[Seen]
  case expr
    Ast.Expr.MethodCall(node) ->
      found = created(node.named)
      return found if !METHODS.include?(node.name)

      found.concat(tested(node.args, node.named, 0))
    Ast.Expr.Call(node) ->
      found = created(node.named)
      bare = METHODS.include?(node.name) and node.piped and !functions.include?(node.name)
      return found if !(bare or QUALIFIED.include?(node.name))

      found.concat(tested(node.args, node.named, 1))
    _ -> []
  end
end

## LINT-ERROR-KIND for each tested literal of a builtin family that is neither a builtin kind (or its family) nor a
## kind that the file creates.
def suggestions(file: String, literals: List[Seen]) -> List[Problems.Problem]
  made: Set[String] = Set.new([])
  for literal in literals
    if literal.created
      made = made.add(literal.kind)
    end
  end

  found: List[Problems.Problem] = []
  for literal in literals
    family = literal.kind.split(".")[0]
    known = KNOWN.include?(literal.kind) or made.include?(literal.kind)
    if !literal.created and FAMILIES.include?(family) and !known
      message = "\"#{literal.kind}\" is not a kind of the builtin #{family} family"
      rule = Rules.ERROR_KIND.with(message: message, help: help(literal.kind, family, made))
      found = found.push(Rules.at(file, rule, literal.span))
    end
  end

  found
end

private

METHODS = Set.new(["is_a?", "kind_of?"])
QUALIFIED = Set.new(["Error.is_a?", "Error.kind_of?"])

# Every name that is_a? takes in a builtin family: each kind and each dotted prefix of one, so the family itself.
KNOWN = Set.new(
  ERROR_KINDS.flat_map do |kind: String|
    (1..kind.split(".").size).to_a.map do |count: Int| kind.split(".").take(count).join(".") end
  end,
)
FAMILIES = Set.new(ERROR_KINDS.map do |kind: String| kind.split(".")[0] end)

# The family an is_a? call tests: the positional argument at `index`, or else the named `family:`. A receiver named
# `error:` (`Error.is_a?(error: e, family: "x")`, or `Error.is_a?("x", error: e)`) leaves one positional slot fewer.
def tested(args: List[Ast.Expr], named: List[Ast.NamedArg], index: Int) -> List[Seen]
  at = index
  if (index > 0 and named.any? { |arg: Ast.NamedArg| arg.name == "error" })
    at = index - 1
  end

  return text(args[at], false) if args.size == at + 1

  return [] if args.size != at

  named.flat_map do |arg: Ast.NamedArg|
    case arg.name
      "family" -> text(arg.value, false)
      _ -> []
    end
  end
end

def created(named: List[Ast.NamedArg]) -> List[Seen]
  named.flat_map do |arg: Ast.NamedArg|
    case arg.name
      "kind" -> text(arg.value, true)
      _ -> []
    end
  end
end

def text(expr: Ast.Expr, made: Bool) -> List[Seen]
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Text(kind) -> [Seen(kind: kind, span: node.span, created: made)]
        _ -> []
      end

    _ -> []
  end
end

# The did-you-mean of the nearest kind of the family, the file's own ones included, or the list of its kinds when none
# is near.
def help(kind: String, family: String, made: Set[String]) -> String
  members = ERROR_KINDS.concat(made.to_a.sort).select do |known: String| known.start_with?("#{family}.") end
  return "#{family} has no dotted kinds: is_a?(\"#{family}\")" if members.size == 0

  case Suggest.did_you_mean(kind, [family].concat(members))
    some(text) -> text
    none -> "the #{family} family has the kinds #{members.join(", ")}; is_a?(\"#{family}\") takes them all"
  end
end
