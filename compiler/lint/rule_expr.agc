## The rules that read one expression: a Bool compared with a literal, a pipe of one step, three nested calls and text
## joined with `+` and `to_s`.

import {ENTRIES} from "../catalog/builtins"
import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"
import Shape from "shape"

## The suggestions for `expr`. `chained` is true when it is the first operand of a pipe, of a `+` chain or of a call
## that is a step (step?): the expression above it judged the whole chain, so it must not be judged again as a chain of
## its own. `aliases` are the module aliases that the file imports.
export def suggestions(file: String, expr: Ast.Expr, chained: Bool, aliases: Set[String]) -> List[Problems.Problem]
  case expr
    Ast.Expr.Binary(node) -> return binary(file, node, chained)
    Ast.Expr.Call(node) -> return single_pipe(file, node, chained).concat(nested_call(file, node, chained, aliases))
    _ -> return []
  end
end

## Whether a pipe could pass the first argument of the call to its function: a plain call with arguments, to a
## function of the file or of a module it imports by alias (`f(x)`, `Paths.join(x, y)`), not a builtin (`puts`, `ok`,
## `List.map`). Any other qualified name is a method of a constant, a type or a value (`ROWS.concat(x)`,
## `Mod.LIMIT.concat(x)`), or a variant, and its first argument is not its receiver.
export def step?(node: Ast.Call, aliases: Set[String]) -> Bool
  if node.piped or node.args.size == 0 or ENTRIES.has_key?(node.name)
    return false
  end

  parts = node.name.split(".")
  return parts.size == 1 or (parts.size == 2 and aliases.include?(parts[0]))
end

def binary(file: String, node: Ast.Binary, chained: Bool) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  if (node.op == "equal" or node.op == "not-equal") and (Shape.flag?(node.left) or Shape.flag?(node.right))
    found = found.push(Rules.at(file, Rules.BOOL_COMPARE, node.span))
  end

  if node.op == "plus" and !chained and joins_text?(node)
    found = found.push(Rules.at(file, Rules.TO_S_CONCAT, node.span))
  end

  return found
end

# A `+` chain with a piece of literal text and a `to_s` call: the join that interpolation writes better. Two Strings
# added with no `to_s` are left alone, since a few sentence-sized pieces are allowed to wrap a long text.
def joins_text?(node: Ast.Binary) -> Bool
  operands = Shape.plus_operands(Ast.Expr.Binary(node))
  literal = operands.any? do |piece: Ast.Expr| Shape.text?(piece) end
  converted = operands.any? do |piece: Ast.Expr| Shape.to_s?(piece) end
  return literal and converted
end

# `x |> f()` where x is not itself the result of a pipe.
def single_pipe(file: String, node: Ast.Call, chained: Bool) -> List[Problems.Problem]
  if !node.piped or chained or node.args.size == 0 or piped_call?(node.args[0])
    return []
  end

  return [Rules.at(file, Rules.SINGLE_PIPE, node.span)]
end

# `h(f(g(x)))`: a call whose first argument is a call whose first argument is a call, which a pipe writes from the
# inside out. The two outer calls become the steps, and a pipe goes into the program's own functions (the style
# guide), so they must be steps (step?): piping to a builtin with a method form is CHECK-PIPE-METHOD, and `ok`,
# `error`, `some` and `puts` read better as calls.
def nested_call(file: String, node: Ast.Call, chained: Bool, aliases: Set[String]) -> List[Problems.Problem]
  if chained or !step?(node, aliases)
    return []
  end

  case node.args[0]
    Ast.Expr.Call(middle) ->
      if step?(middle, aliases) and call?(middle.args[0])
        return [Rules.at(file, Rules.NESTED_CALL, node.span)]
      end

      return []
    _ -> return []
  end
end

def call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(_) -> return true
    _ -> return false
  end
end

# Whether the expression is a piped call, as `x |> try f()` is too.
def piped_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> return node.piped
    Ast.Expr.Try(wrapper) -> return piped_call?(wrapper.operand)
    _ -> return false
  end
end
