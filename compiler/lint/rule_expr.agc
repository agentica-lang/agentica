## The rules that read one expression: a Bool compared with a literal, a pipe of one step and text joined with `+` and
## `to_s`.

import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"
import Shape from "shape"

## The suggestions for `expr`. `chained` is true when it is the first operand of a pipe or of a `+` chain: the
## expression above it judged the whole chain, so it must not be judged again as a chain of its own.
export def suggestions(file: String, expr: Ast.Expr, chained: Bool) -> List[Problems.Problem]
  case expr
    Ast.Expr.Binary(node) -> return binary(file, node, chained)
    Ast.Expr.Call(node) -> return single_pipe(file, node, chained)
    _ -> return []
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

# Whether the expression is a piped call, as `x |> try f()` is too.
def piped_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> return node.piped
    Ast.Expr.Try(wrapper) -> return piped_call?(wrapper.operand)
    _ -> return false
  end
end
