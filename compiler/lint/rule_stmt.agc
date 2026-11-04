## The rules that read one statement: a String grown by `+` in a loop, an `if` chain on one value and a negated `if`
## with an `else`.

import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"
import Shape from "shape"

## The suggestions for `stmt`. `in_loop` is true below a `for` or `while` of the same function body (a block starts
## again: its locals do not live across calls). `strings` are the names of the function that hold a String.
export def suggestions(file: String, stmt: Ast.Stmt, in_loop: Bool, strings: Set[String]) -> List[Problems.Problem]
  case stmt
    Ast.Stmt.Binding(node) -> return appended(file, node, in_loop, strings)
    Ast.Stmt.If(node) -> return branches(file, node)
    _ -> return []
  end
end

# `s = s + piece` (and `s += piece`, which the parser writes the same way) in a loop, where s is a String. The names
# come from the function, so `s = s + part` is found when s was set to a literal or declared String, and a literal or
# `to_s` piece shows a String by itself, as only a String adds to a String.
def appended(file: String, node: Ast.Binding, in_loop: Bool, strings: Set[String]) -> List[Problems.Problem]
  if !in_loop
    return []
  end

  operands = Shape.plus_operands(node.value)
  if operands.size < 2 or Shape.read_name(operands[0]) != some(node.name)
    return []
  end

  pieces = operands.drop(1)
  if strings.include?(node.name) or pieces.any? do |piece: Ast.Expr| Shape.text?(piece) or Shape.to_s?(piece) end
    return [Rules.at(file, Rules.STRING_APPEND, node.span)]
  end

  return []
end

def branches(file: String, node: Ast.IfStmt) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  first = node.branches[0].condition
  if node.branches.size == 1 and node.else_body.some? and negated?(first)
    found = found.push(Rules.at(file, Rules.NEGATED_ELSE, Ast.expr_span(first)))
  end

  if on_one_value?(node)
    found = found.push(Rules.at(file, Rules.IF_CHAIN, Ast.expr_span(first)))
  end

  return found
end

def negated?(condition: Ast.Expr) -> Bool
  case condition
    Ast.Expr.Unary(node) -> return node.op == "not"
    _ -> return false
  end
end

# Three or more branches (the `else` counts as one) whose conditions all test the same variable against a literal.
def on_one_value?(node: Ast.IfStmt) -> Bool
  arms = node.branches.size
  if node.else_body.some?
    arms += 1
  end

  first = tested(node.branches[0].condition)
  if arms < 3 or first.none?
    return false
  end

  return node.branches.all? do |branch: Ast.IfBranch| tested(branch.condition) == first end
end

# The variable that `name == literal` tests, `none` for any other condition.
def tested(condition: Ast.Expr) -> Optional[String]
  case condition
    Ast.Expr.Binary(node) ->
      if node.op != "equal"
        return none
      end

      case node.right
        Ast.Expr.Literal(_) -> return Shape.read_name(node.left)
        _ -> return none
      end

    _ -> return none
  end
end
