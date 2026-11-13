## The first argument of a builtin call that must be a collection, a channel, a task or a Result Each checks
## argument 0 against the context given and returns the new state with its type, or CHECK-TYPE-MISMATCH naming the type
## it should have been.

import Ast from "../syntax/ast"
import T from "../syntax/types"
import State from "check_state"

## Argument 0 as a Map[K, V].
def map_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  shaped(cx, st, site, context, "Map", T.Type.Map(T.Type.Var("K"), T.Type.Var("V")))
end

## Argument 0 as a Set[T].
def set_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  shaped(cx, st, site, context, "Set", T.Type.Set(T.Type.Var("T")))
end

## Argument 0 as a List[T].
def list_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  shaped(cx, st, site, context, "List", T.Type.List(T.Type.Var("T")))
end

## Argument 0 as an ATS[K, V].
def ats_argument(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  shaped(cx, st, site, T.Type.Unknown, "ATS", T.Type.ATS(T.Type.Var("K"), T.Type.Var("V")))
end

## Argument 0 as a Channel[T].
def channel_argument(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  shaped(cx, st, site, T.Type.Unknown, "Channel", T.Type.Channel(T.Type.Var("T")))
end

## Argument 0 as an Address[T].
def address_argument(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  shaped(cx, st, site, T.Type.Unknown, "Address", T.Type.Address(T.Type.Var("T")))
end

## Argument 0 as a Task[R], or the TaskRef of Task.current, which the builtins of this argument take too (Task.cancel,
## Task.monitor, id); only an await needs the result type.
def task_argument(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  if !T.is?(out.type, "Task") and !task_ref?(out.type)
    return error(State.mismatch(cx, out.st, T.Type.Task(T.Type.Var("R")), out.type, Ast.expr_span(site.args[0])))
  end

  ok(out)
end

## True for the TaskRef of Task.current.
def task_ref?(type: T.Type) -> Bool = T.is?(type, "Opaque") and T.name(type) == "TaskRef"

## Argument 0 as a Result[T].
def result_argument(cx: State.Cx, st: State.St, site: State.Site, context: T.Type) -> Result[State.Out]
  shaped(cx, st, site, context, "Result", T.Type.Result(T.Type.Var("T")))
end

## True for a list literal with no elements.
def empty_list?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.ListLit(list) -> list.elements.size == 0
    _ -> false
  end
end

## True for a map literal with no entries.
def empty_map?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.MapLit(map) -> map.entries.size == 0
    _ -> false
  end
end

private

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
  return error(State.mismatch(cx, out.st, shape, out.type, Ast.expr_span(site.args[0]))) if !T.is?(out.type, word)

  ok(out)
end
