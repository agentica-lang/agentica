## Small questions the rules ask of an expression, so each rule reads as its style sentence.

import Ast from "../syntax/ast"

## Whether the expression is `true` or `false`.
def flag?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Flag(_) -> true
        _ -> false
      end

    _ -> false
  end
end

## Whether the expression is a string literal or an interpolated string.
def text?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Text(_) -> true
        _ -> false
      end

    Ast.Expr.Interpolation(_) -> true
    _ -> false
  end
end

## Whether the expression is `to_s` on a value, written `n.to_s` or `n.to_s()`.
def to_s?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.FieldAccess(node) -> node.name == "to_s"
    Ast.Expr.MethodCall(node) -> node.name == "to_s" and node.args.size == 0
    _ -> false
  end
end

## The operands of a `+` chain, left to right: the left side is followed down while it is a `+` itself, so
## `a + b + c` gives [a, b, c]. Anything else is a chain of one operand.
def plus_operands(expr: Ast.Expr) -> List[Ast.Expr]
  rights: List[Ast.Expr] = []
  left = expr
  following = true
  while following
    case left
      Ast.Expr.Binary(node) ->
        if node.op == "plus"
          rights = rights.push(node.right)
          left = node.left
        else
          following = false
        end

      _ -> following = false
    end
  end

  [left].concat(rights.reverse)
end

## The name a variable read has, `none` for any other expression.
def read_name(expr: Ast.Expr) -> Optional[String]
  case expr
    Ast.Expr.Name(node) -> some(node.name)
    _ -> none
  end
end
