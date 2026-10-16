## The first argument of a builtin call that must be a collection, a channel or a Result Each checks
## argument 0 against the context given and returns the new state with its type, or CHECK-TYPE-MISMATCH naming the type
## it should have been.

import Ast from "ast"
import State from "check_state"
import T from "types"

## Argument 0 as a Map[K, V].
export def map_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  return shaped(cx, st, site, context, "Map", T.Type.Map(T.Type.Var("K"), T.Type.Var("V")))
end

## Argument 0 as a Set[T].
export def set_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  return shaped(cx, st, site, context, "Set", T.Type.Set(T.Type.Var("T")))
end

## Argument 0 as a List[T].
export def list_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  return shaped(cx, st, site, context, "List", T.Type.List(T.Type.Var("T")))
end

## Argument 0 as a Channel[T].
export def channel_argument(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  return shaped(cx, st, site, T.Type.Unknown, "Channel", T.Type.Channel(T.Type.Var("T")))
end

## Argument 0 as a Result[T].
export def result_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  return shaped(cx, st, site, context, "Result", T.Type.Result(T.Type.Var("T")))
end

## True for a list literal with no elements.
export def empty_list?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.ListLit(list) -> return list.elements.size == 0
    _ -> return false
  end
end

## True for a map literal with no entries.
export def empty_map?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.MapLit(map) -> return map.entries.size == 0
    _ -> return false
  end
end

# Argument 0, which must have the variant named by word; shape is the type the message says it should have.
def shaped(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  context: T.Type,
  word: String,
  shape: T.Type,
) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], context)
  if !T.is(out.type, word)
    return error(State.mismatch(cx, out.st, shape, out.type, Ast.expr_span(site.args[0])))
  end
  return ok(out)
end
