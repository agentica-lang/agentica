## The rules that read one expression: a Bool compared with a literal, a pipe of one step, three nested calls, text
## joined with `+` and `to_s`, and a method chain that passes lambdas.

import {ENTRIES} from "../catalog/builtins"
import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Rules from "rules"
import Shape from "shape"

## The suggestions for `expr`. `chained` is true when it is the first operand of a pipe, of a `+` chain or of a call
## that is a step (step?): the expression above it judged the whole chain, so it must not be judged again as a chain of
## its own. `aliases` are the module aliases that the file imports.
export def suggestions(file: String, expr: Ast.Expr, chained: Bool, aliases: Set[String]) -> List[Problems.Problem]
  case expr
    Ast.Expr.Binary(node) -> binary(file, node, chained)
    Ast.Expr.Call(node) -> single_pipe(file, node, chained).concat(nested_call(file, node, chained, aliases))
    Ast.Expr.MethodCall(node) -> lambda_chain(file, expr, node.span, chained)
    Ast.Expr.FieldAccess(node) -> lambda_chain(file, expr, node.span, chained)
    _ -> []
  end
end

## Whether a pipe could pass the first argument of the call to its function: a plain call with arguments, to a
## function of the file or of a module it imports by alias (`f(x)`, `Paths.join(x, y)`), not a builtin (`puts`, `ok`,
## `List.map`), and not a variant (`Domain.Some(x)`: the member after the alias starts with a capital). Any other
## qualified name is a method of a constant, a type or a value (`ROWS.concat(x)`, `Mod.LIMIT.concat(x)`), or a
## variant, and its first argument is not its receiver.
export def step?(node: Ast.Call, aliases: Set[String]) -> Bool
  return false if node.piped or node.args.size == 0 or ENTRIES.has_key?(node.name)

  parts = node.name.split(".")
  if parts.size == 2
    member = parts[1]
    return aliases.include?(parts[0]) and member.slice(0, 1) != member.slice(0, 1).upcase
  end

  parts.size == 1
end

# `xs.map(->(x) { ... }).select(->(x) { ... }).sum`: a method chain whose links, from the first that passes a lambda to
# the end, are three or more reads better as a pipe. The walk judges the chain at its last link, so a link inside it is
# `chained`.
def lambda_chain(file: String, expr: Ast.Expr, span: Source.Span, chained: Bool) -> List[Problems.Problem]
  return [] if chained or lambda_steps(expr) < 3

  [Rules.at(file, Rules.LAMBDA_CHAIN, span)]
end

# How many links of the chain that ends with `expr` a pipe would write, from the first link that passes a lambda to the
# end; 0 when no link does. A link is a method call, or a name without arguments as the last link only
# (`.sum`): further
# in it may be a struct field, which a pipe cannot name, and lint has no types to tell.
def lambda_steps(expr: Ast.Expr) -> Int
  links = 0
  steps = 0
  current = expr
  case current
    Ast.Expr.FieldAccess(node) ->
      links = 1
      current = node.target
    _ -> links = 0
  end

  while method_call?(current)
    case current
      Ast.Expr.MethodCall(node) ->
        links += 1
        if node.args.any? do |arg: Ast.Expr| lambda?(arg) end
          steps = links
        end

        current = node.target
      _ -> break
    end
  end

  steps
end

def method_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.MethodCall(_) -> true
    _ -> false
  end
end

def lambda?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.BlockLit(node) -> node.lambda
    _ -> false
  end
end

def binary(file: String, node: Ast.Binary, chained: Bool) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  if (node.op == "equal" or node.op == "not-equal") and (Shape.flag?(node.left) or Shape.flag?(node.right))
    found = found.push(Rules.at(file, Rules.BOOL_COMPARE, node.span))
  end

  if node.op == "plus" and !chained and joins_text?(node)
    found = found.push(Rules.at(file, Rules.TO_S_CONCAT, node.span))
  end

  found
end

# A `+` chain with a piece of literal text and a `to_s` call: the join that interpolation writes better. Two Strings
# added with no `to_s` are left alone, since a few sentence-sized pieces are allowed to wrap a long text.
def joins_text?(node: Ast.Binary) -> Bool
  operands = Shape.plus_operands(Ast.Expr.Binary(node))
  literal = operands.any? do |piece: Ast.Expr| Shape.text?(piece) end
  converted = operands.any? do |piece: Ast.Expr| Shape.to_s?(piece) end
  literal and converted
end

# `x |> f()` where x is not itself the result of a pipe.
def single_pipe(file: String, node: Ast.Call, chained: Bool) -> List[Problems.Problem]
  return [] if !node.piped or chained or node.args.size == 0 or piped_call?(node.args[0])

  [Rules.at(file, Rules.SINGLE_PIPE, node.span)]
end

# `h(f(g(x)))`: a call whose first argument is a call whose first argument is a call, which a pipe writes from the
# inside out. The two outer calls become the steps, and a pipe goes into the program's own functions (the style
# guide), so they must be steps (step?): piping to a builtin with a method form is CHECK-PIPE-METHOD, and `ok`,
# `error`, `some` and `puts` read better as calls.
def nested_call(file: String, node: Ast.Call, chained: Bool, aliases: Set[String]) -> List[Problems.Problem]
  return [] if chained or !step?(node, aliases)

  case node.args[0]
    Ast.Expr.Call(middle) ->
      return [Rules.at(file, Rules.NESTED_CALL, node.span)] if step?(middle, aliases) and call?(middle.args[0])

      []
    _ -> []
  end
end

def call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(_) -> true
    _ -> false
  end
end

# Whether the expression is a piped call, as `x |> try f()` is too.
def piped_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> node.piped
    Ast.Expr.Try(wrapper) -> piped_call?(wrapper.operand)
    _ -> false
  end
end
