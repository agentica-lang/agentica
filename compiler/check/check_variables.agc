## CHECK-UNUSED-VARIABLE: a name that a function introduces and never reads is an error, unless it starts with `_`.
## The names are watched while the function is checked (State.introduce_local, State.read); this runs at its end.

import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import T from "../syntax/types"
import State from "check_state"
import Unused from "check_unused"

## A node and whether a read of the name at it is a use: it sits where the value of the name flows into a call.
struct Reach
  node: Walk.Node
  flows: Bool
end

## CHECK-UNUSED-VARIABLE for the name that starts first in the source among those that nothing read, in a file that is
## not lenient. The scope of every name is the function (or constant) that introduced it, which is why the state holds
## no name of another one.
def check(cx: State.Cx, st: State.St) -> Result[Bool]
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

## True when a read of `name` in the value assigned to it is a use of it. The value of the name must flow into a call
## that can fail or have effects, so the call cannot be dropped: the read is inside the operand of a `try`, the
## receiver of `.unwrap!`, the arguments of a call of a function of the program (not of the standard library), or the
## arguments of an invoke (`f.call(x)`). Any other read does not count, as in `x = x + 1`, `xs = xs.push(wrap(v))` or
## `total += price(v)`: the call there only feeds a new value. A read of a block is looked at like any other.
def read_by_a_call?(cx: State.Cx, name: String, value: Ast.Expr) -> Bool
  work: List[Reach] = [Reach(node: Walk.Node.Expr(value), flows: false)]
  at = 0
  while at < work.size
    reach = work[at]
    at += 1
    case reach.node
      Walk.Node.Expr(Ast.Expr.Name(ref)) -> return true if reach.flows and ref.name == name
      _ -> work = work
    end

    flows = flows_into(cx, reach)
    for child in Walk.children(reach.node)
      work = work.push(Reach(node: child, flows: flows))
    end
  end

  false
end

private

# Whether the children of a node are where the value flows: it is already so, or the node is a `try`, a call of the
# program, an invoke, or `.unwrap!` (written with or without parentheses; only its receiver is below it).
def flows_into(cx: State.Cx, reach: Reach) -> Bool
  return true if reach.flows

  case reach.node
    Walk.Node.Expr(Ast.Expr.Try(_)) -> true
    Walk.Node.Expr(Ast.Expr.Invoke(_)) -> true
    Walk.Node.Expr(Ast.Expr.MethodCall(call)) -> call.name == "unwrap!"
    Walk.Node.Expr(Ast.Expr.FieldAccess(access)) -> access.name == "unwrap!"
    Walk.Node.Expr(Ast.Expr.Call(call)) -> program_call?(cx, call.name)
    _ -> false
  end
end

# Whether the linked name is a function of the program: it is declared, in a module that is not of the standard
# library.
def program_call?(cx: State.Cx, name: String) -> Bool
  return false if !cx.functions.key?(name)

  case name.index_of("::")
    some(marker) -> !cx.std.include?(name.slice(0, marker + 2))
    none -> true
  end
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
