## CHECK-UNUSED-VARIABLE: a name that a function introduces and never reads is an error, unless it starts with `_`.
## The names are watched while the function is checked (State.introduce_local, State.read); this runs at its end.

import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import T from "../syntax/types"
import State from "check_state"
import Unused from "check_unused"

## CHECK-UNUSED-VARIABLE for the name that starts first in the source among those that nothing read, in a file that is
## not lenient. The scope of every name is the function (or constant) that introduced it, which is why the state holds
## no name of another one.
export def check(cx: State.Cx, st: State.St) -> Result[Bool]
  return ok(true) if st.locals.size == 0 or cx.lenient.include?(cx.file)

  first = -1
  for key in st.locals.keys
    if !st.reads.include?(key) and (first < 0 or key < first)
      first = key
    end
  end

  return ok(true) if first < 0

  local = st.locals[first]
  error(
    State.fail_help(
      cx,
      st,
      "CHECK-UNUSED-VARIABLE",
      "#{label(local.origin)} \"#{local.name}\" is never read",
      local.span,
      help(cx, st, first, local),
    ),
  )
end

def label(origin: State.Origin) -> String
  case origin
    State.Origin.Variable -> "the variable"
    State.Origin.ForVariable -> "the for variable"
    State.Origin.BlockParameter -> "the block parameter"
    State.Origin.PatternBinding -> "the pattern name"
  end
end

def help(cx: State.Cx, st: State.St, key: Int, local: State.Local) -> String
  keep = "name it _#{local.name} if it is unused on purpose"
  case local.origin
    State.Origin.ForVariable -> "write for _ in #{value_text(cx, local.value)}, or #{keep}"
    State.Origin.BlockParameter -> "write _ in its place (|_, i|), or #{keep}"
    State.Origin.PatternBinding -> "write _ to match without binding the value, or #{keep}"
    State.Origin.Variable -> variable_help(cx, st, key, local, keep)
  end
end

def variable_help(cx: State.Cx, st: State.St, key: Int, local: State.Local, keep: String) -> String
  text = value_text(cx, local.value)
  if st.writes.include?(key) and has_try?(local.value)
    return "it is only updated, never read; remove it and keep its try as a statement, or #{keep}"
  end

  # Removing a name whose value holds a `try` would drop the error that the `try` returns to the caller.
  return "write #{text} as a statement, without the name, or #{keep}" if try?(local.value)

  return "discard it with _ = #{text} to keep its try, or #{keep}" if has_try?(local.value)

  if T.is?(local.type, "Result") and local.value.some?
    return "#{Unused.handle_result_help(text, local.tryable)}, or #{keep}"
  end

  return "it is only updated, never read; remove it, or #{keep}" if st.writes.include?(key)

  return "remove it, keep the call as a statement if it has effects, or #{keep}" if call?(local.value)

  "remove it, or #{keep}"
end

# True when the value is a `try` itself.
def try?(value: Optional[Ast.Expr]) -> Bool
  case value
    some(found) ->
      case found
        Ast.Expr.Try(_) -> true
        _ -> false
      end

    none -> false
  end
end

# True when a `try` is anywhere in the value, outside any block. It walks with a worklist, as the other stages do.
def has_try?(value: Optional[Ast.Expr]) -> Bool
  case value
    some(found) ->
      work: List[Walk.Node] = [Walk.Node.Expr(found)]
      at = 0
      while at < work.size
        node = work[at]
        at += 1
        case node
          Walk.Node.Expr(Ast.Expr.Try(_)) -> return true
          # A `try` in a block returns from the block, not from the scope of the variable.
          Walk.Node.Expr(Ast.Expr.BlockLit(_)) -> work = work
          _ -> work = work.concat(Walk.children(node))
        end
      end

      false
    none -> false
  end
end

def call?(value: Optional[Ast.Expr]) -> Bool
  case value
    some(found) ->
      case found
        Ast.Expr.Call(_) -> true
        Ast.Expr.MethodCall(_) -> true
        _ -> false
      end

    none -> false
  end
end

# The source text of the value, or `...` when there is none.
def value_text(cx: State.Cx, value: Optional[Ast.Expr]) -> String
  case value
    some(found) -> Unused.value_text(cx, found)
    none -> "..."
  end
end
