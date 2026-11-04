## CHECK-UNUSED-VARIABLE: a name that a function introduces and never reads is an error, unless it starts with `_`.
## The names are watched while the function is checked (State.introduce_local, State.read); this runs at its end.

import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import T from "../syntax/types"
import State from "check_state"

# The longest text of a value that a help copies; a longer or multi-line one is written as `...`.
MAX_VALUE_TEXT = 60

## CHECK-UNUSED-VARIABLE for the name that starts first in the source among those that nothing read, in a file that is
## not lenient. The scope of every name is the function (or constant) that introduced it, which is why the state holds
## no name of another one.
export def check(cx: State.Cx, st: State.St) -> Result[Bool]
  if st.locals.size == 0 or cx.lenient.include?(cx.file)
    return ok(true)
  end

  first = -1
  for key in st.locals.keys
    if !st.reads.include?(key) and (first < 0 or key < first)
      first = key
    end
  end

  if first < 0
    return ok(true)
  end

  local = st.locals[first]
  return error(
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
    State.Origin.Variable -> return "the variable"
    State.Origin.ForVariable -> return "the for variable"
    State.Origin.BlockParameter -> return "the block parameter"
    State.Origin.PatternBinding -> return "the pattern name"
  end
end

def help(cx: State.Cx, st: State.St, key: Int, local: State.Local) -> String
  keep = "name it _#{local.name} if it is unused on purpose"
  case local.origin
    State.Origin.ForVariable -> return "write for _ in #{value_text(cx, local.value)}, or #{keep}"
    State.Origin.BlockParameter -> return "write _ in its place (|_, i|), or #{keep}"
    State.Origin.PatternBinding -> return "write _ to match without binding the value, or #{keep}"
    State.Origin.Variable -> return variable_help(cx, st, key, local, keep)
  end
end

def variable_help(cx: State.Cx, st: State.St, key: Int, local: State.Local, keep: String) -> String
  text = value_text(cx, local.value)
  # Removing a name whose value holds a `try` would drop the error that the `try` returns to the caller.
  if try?(local.value)
    return "write #{text} as a statement, without the name, or #{keep}"
  end

  if has_try?(local.value)
    return "discard it with _ = #{text} to keep its try, or #{keep}"
  end

  if T.is?(local.type, "Result") and local.value.some?
    attempt = ""
    if local.tryable
      attempt = "try #{text}, "
    end

    return (
      "handle the Result: #{attempt}a case on ok(_) and error(message), or .unwrap!; " +
      "or discard it with _ = #{text}, or #{keep}"
    )
  end

  if st.writes.include?(key)
    return "it is only updated, never read; remove it, or #{keep}"
  end

  if call?(local.value)
    return "remove it, keep the call as a statement if it has effects, or #{keep}"
  end

  return "remove it, or #{keep}"
end

# True when the value is a `try` itself.
def try?(value: Optional[Ast.Expr]) -> Bool
  case value
    some(found) ->
      case found
        Ast.Expr.Try(_) -> return true
        _ -> return false
      end

    none -> return false
  end
end

# True when a `try` is anywhere in the value. It walks with a worklist, as the other stages do.
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
          _ -> work = work.concat(Walk.children(node))
        end
      end

      return false
    none -> return false
  end
end

def call?(value: Optional[Ast.Expr]) -> Bool
  case value
    some(found) ->
      case found
        Ast.Expr.Call(_) -> return true
        Ast.Expr.MethodCall(_) -> return true
        _ -> return false
      end

    none -> return false
  end
end

# The source text of the value, or `...` when it is long or spans lines.
def value_text(cx: State.Cx, value: Optional[Ast.Expr]) -> String
  case value
    some(found) ->
      span = Ast.expr_span(found)
      text = cx.texts.get(cx.file).unwrap_or("").slice(span.start.offset, span.stop.offset - span.start.offset)
      if text.length > MAX_VALUE_TEXT or text.contains?("\n")
        return "..."
      end

      return text
    none -> return "..."
  end
end
