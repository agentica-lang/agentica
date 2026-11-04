## Small questions the rules ask of an expression, so each rule reads as its style sentence.

import Ast from "../syntax/ast"

## Whether the expression is `true` or `false`.
export def flag?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Flag(_) -> return true
        _ -> return false
      end

    _ -> return false
  end
end

## Whether the expression is a string literal or an interpolated string.
export def text?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Text(_) -> return true
        _ -> return false
      end

    Ast.Expr.Interpolation(_) -> return true
    _ -> return false
  end
end

## Whether the expression is `to_s` on a value, written `n.to_s` or `n.to_s()`.
export def to_s?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.FieldAccess(node) -> return node.name == "to_s"
    Ast.Expr.MethodCall(node) -> return node.name == "to_s" and node.args.size == 0
    _ -> return false
  end
end

## The operands of a `+` chain, left to right: the left side is followed down while it is a `+` itself, so
## `a + b + c` gives [a, b, c]. Anything else is a chain of one operand.
export def plus_operands(expr: Ast.Expr) -> List[Ast.Expr]
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

  return [left].concat(rights.reverse)
end

## The name a variable read has, `none` for any other expression.
export def read_name(expr: Ast.Expr) -> Optional[String]
  case expr
    Ast.Expr.Name(node) -> return some(node.name)
    _ -> return none
  end
end
