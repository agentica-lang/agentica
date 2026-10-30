## Which expression a position is on (docs/future/39-semantic-cli.md, 39.3): the innermost expression of a module whose
## span holds the position and that checking gave a type. It walks the tree with a worklist and no recursion, with the
## children of `check/const_walk.agc`, so a deep tree cannot reach the limit of VM calls.

import Walk from "../check/const_walk"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"

## The innermost expression of `module` that holds the character at `offset` and has a type in `types` (a list indexed
## by node id, `Checked.types`), or Absent. Among the expressions that hold it, the one with the shortest span wins,
## and the deepest of two with the same span; so `a` in `a.b` and `b` in `f(b)` are not the whole access or call. Only
## the function or constant that holds the position is walked. A call that is piped (`x |> f(y)`) holds `f(y)` but not
## `x`, so no node is skipped for its parent's span.
export def innermost(module: Linker.LinkedModule, types: List[T.Type], offset: Int) -> Ast.Maybe[Ast.Expr]
  best: Ast.Maybe[Ast.Expr] = Ast.Maybe.Absent
  best_size = -1
  work = roots(module, offset)
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      Walk.Node.Expr(expr) ->
        span = Ast.expr_span(expr)
        size = span.stop.offset - span.start.offset
        closer = best_size < 0 or size <= best_size
        if closer and holds?(span, offset) and typed?(types, expr)
          best = Ast.Maybe.Present(expr)
          best_size = size
        end

      Walk.Node.Stmt(_) -> best = best
    end

    for child in Walk.children(node)
      work = work.push(child)
    end
  end

  return best
end

## Whether the span, which ends before its last character, holds the character at `offset`.
export def holds?(span: Source.Span, offset: Int) -> Bool
  return span.start.offset <= offset and offset < span.stop.offset
end

# The bodies and defaults of the functions that hold the position, and the values of the constants that do.
def roots(module: Linker.LinkedModule, offset: Int) -> List[Walk.Node]
  out: List[Walk.Node] = []
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        if holds?(node.span, offset)
          for param in node.params
            out = out.concat(default_of(param.default))
          end

          out = out.concat(node.body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end)
        end

      Ast.Decl.Constant(node) ->
        if holds?(node.span, offset)
          out = out.push(Walk.Node.Expr(node.value))
        end

      Ast.Decl.Struct(node) ->
        if holds?(node.span, offset)
          for field in node.fields
            out = out.concat(default_of(field.default))
          end
        end

      _ -> out = out
    end
  end

  return out
end

def default_of(default: Ast.Maybe[Ast.Expr]) -> List[Walk.Node]
  case default
    Ast.Maybe.Present(value) -> return [Walk.Node.Expr(value)]
    Ast.Maybe.Absent -> return []
  end
end

# A node the checker gave no type, such as the name of a type in a position it does not check, is not an answer.
def typed?(types: List[T.Type], expr: Ast.Expr) -> Bool
  id = Ast.expr_id(expr)
  return id < types.size and !T.unknown?(types[id])
end
