## Which expression a position is on (docs/grammar/06b-builtins.md): the innermost expression of a module whose
## span holds the position and that checking gave a type. It walks the tree with a worklist and no recursion, with the
## children of `syntax/ast_walk.agc`, so a deep tree cannot reach the limit of VM calls.

import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import Source from "../syntax/source"
import T from "../syntax/types"

## The innermost expression of `module` that holds the character at `offset` and has a type in `types` (a list indexed
## by node id, `Checked.types`), or `none`. Among the expressions that hold it, the one with the shortest span wins,
## and the deepest of two with the same span; so `a` in `a.b` and `b` in `f(b)` are not the whole access or call. Only
## the function or constant that holds the position is walked. A call that is piped (`x |> f(y)`) holds `f(y)` but not
## `x`, so no node is skipped for its parent's span.
export def innermost(module: Linker.LinkedModule, types: List[T.Type], offset: Int) -> Optional[Ast.Expr]
  best: Optional[Ast.Expr] = none
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
          best = some(expr)
          best_size = size
        end

      Walk.Node.Stmt(_) -> best = best
    end

    for child in Walk.children(node)
      work = work.push(child)
    end
  end

  best
end

## `linked` with the module that holds `offset` in its root file first, which is the module a query answers a position
## from: a module block of the root file is a module of its own (Linker.LinkedModule), so a position inside one puts it
## first. Elsewhere `linked` is as it was.
export def focus(linked: Linker.Linked, offset: Int) -> Linker.Linked
  root = Linker.home_key(linked.modules[0])
  here = holder(linked.modules.filter do |module: Linker.LinkedModule| Linker.home_key(module) == root end, offset)
  return linked if here.key == linked.modules[0].key

  others = linked.modules.filter do |module: Linker.LinkedModule| module.key != here.key end
  linked.with(modules: [here].concat(others))
end

## The module among `modules`, a file and its module blocks, whose own declarations hold `offset`: the block whose span
## holds it, else the file.
export def holder(modules: List[Linker.LinkedModule], offset: Int) -> Linker.LinkedModule
  for module in modules
    return module if module.block != "" and holds?(module.parsed.span, offset)
  end

  files = modules.filter do |module: Linker.LinkedModule| module.block == "" end
  return files[0] if files.size > 0

  modules[0]
end

## Whether the span, which ends before its last character, holds the character at `offset`.
export def holds?(span: Source.Span, offset: Int) -> Bool = span.start.offset <= offset and offset < span.stop.offset

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

  out
end

def default_of(default: Optional[Ast.Expr]) -> List[Walk.Node]
  case default
    some(value) -> [Walk.Node.Expr(value)]
    none -> []
  end
end

# A node the checker gave no type, such as the name of a type in a position it does not check, is not an answer.
def typed?(types: List[T.Type], expr: Ast.Expr) -> Bool
  id = Ast.expr_id(expr)
  id < types.size and !T.unknown?(types[id])
end
