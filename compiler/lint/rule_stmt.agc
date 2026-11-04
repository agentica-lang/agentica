## The rules that read one statement: a String grown by `+` in a loop, an `if` chain on one value and a negated `if`
## with an `else`.

import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"
import Shape from "shape"

## Where a name of a function was set: the source `offset` of the binding, the `path` of the loops it sits in (the ids
## of the enclosing `for` and `while`, outermost first; a parameter has the empty path and comes first) and whether
## it holds a String.
export struct Origin
  offset: Int
  path: List[Int]
  string: Bool
end

## The origins of every name of a function, for the String rule.
export struct Locals
  origins: Map[String, List[Origin]]
end

## The suggestions for `stmt`. `path` is the loops that the statement sits in, of the same function body (a block
## starts again: its locals do not live across calls). `locals` are the names of the function.
export def suggestions(file: String, stmt: Ast.Stmt, path: List[Int], locals: Locals) -> List[Problems.Problem]
  case stmt
    Ast.Stmt.Binding(node) -> return appended(file, node, path, locals)
    Ast.Stmt.If(node) -> return branches(file, node)
    _ -> return []
  end
end

# `s = s + piece` (and `s += piece`, which the parser writes the same way) in a loop, where s is a String that was set
# outside that loop: the nearest earlier binding of s is in fewer loops than this one, so the String lives across the
# passes and grows. A String made fresh in the body of the only loop is short. A literal or `to_s` piece shows a String
# by itself, as only a String adds to a String.
def appended(file: String, node: Ast.Binding, path: List[Int], locals: Locals) -> List[Problems.Problem]
  operands = Shape.plus_operands(node.value)
  if path.size == 0 or operands.size < 2 or Shape.read_name(operands[0]) != some(node.name)
    return []
  end

  case nearest(locals.origins.get(node.name, []), node.span.start.offset)
    none -> return []
    some(origin) ->
      pieces = operands.drop(1)
      texts = pieces.any? do |piece: Ast.Expr| Shape.text?(piece) or Shape.to_s?(piece) end
      if outside?(origin.path, path) and (origin.string or texts)
        return [Rules.at(file, Rules.STRING_APPEND, node.span)]
      end

      return []
  end
end

# The binding with the greatest offset below `before`.
def nearest(origins: List[Origin], before: Int) -> Optional[Origin]
  best: Optional[Origin] = none
  for origin in origins
    if origin.offset < before
      case best
        some(held) ->
          if held.offset < origin.offset
            best = some(origin)
          end

        none -> best = some(origin)
      end
    end
  end

  return best
end

# Whether `inner` starts with all of `outer` and has more loops.
def outside?(outer: List[Int], inner: List[Int]) -> Bool
  return outer.size < inner.size and inner.take(outer.size) == outer
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
