## CHECK-UNUSED-VALUE (src/checker.rkt: check-unused-value!): a value that is dropped, and could only have been used
## for itself, is an error.

import Ast from "ast"
import Model from "builtin_model"
import State from "check_state"
import T from "types"

## CHECK-UNUSED-VALUE when a value that is dropped could only have been used for itself: a pure builtin, a to_s on a
## data value, a .with. Anything else, and any Void value, is fine.
export def check_unused_value(cx: State.Cx, st: State.St, value: Ast.Expr, type: T.Type) -> Result[Bool]
  if T.is(type, "Void")
    return ok(true)
  end
  resolved = resolution(st, value)
  name = call_name(value, resolved)
  entry = cx.catalog.entries.get(name)
  if unused_result?(value, resolved, entry)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNUSED-VALUE",
        "the result of #{unused_subject(name)} is not used",
        Ast.expr_span(value),
        unused_help(value, resolved, entry),
      ),
    )
  end
  return ok(true)
end

# What a method call or field access resolved to; Absent for any other expression.
def resolution(st: State.St, value: Ast.Expr) -> Ast.Optional[State.Resolved]
  case value
    Ast.Expr.MethodCall(node) -> return found_resolution(st, node.id)
    Ast.Expr.FieldAccess(node) -> return found_resolution(st, node.id)
    _ -> return Ast.Optional.Absent
  end
end

def found_resolution(st: State.St, id: Int) -> Ast.Optional[State.Resolved]
  found = st.resolved.get(id)
  if found.ok?
    return Ast.Optional.Present(found.unwrap!)
  end
  return Ast.Optional.Absent
end

# The builtin a dropped value calls: the one a method resolved to, or a call written by name. "" for anything else.
def call_name(value: Ast.Expr, resolved: Ast.Optional[State.Resolved]) -> String
  case resolved
    Ast.Optional.Present(found) -> return resolved_call_name(found)
    Ast.Optional.Absent -> return plain_call_name(value)
  end
end

def resolved_call_name(found: State.Resolved) -> String
  case found
    State.Resolved.Call(name, receiver) -> return name
    _ -> return ""
  end
end

def plain_call_name(value: Ast.Expr) -> String
  case value
    Ast.Expr.Call(node) -> return node.name
    _ -> return ""
  end
end

# True when dropping the value loses something: a method that resolved to the receiver, to_s or inspect, a struct
# update, or a call of a pure builtin.
def unused_result?(value: Ast.Expr, resolved: Ast.Optional[State.Resolved], entry: Result[Model.Builtin]) -> Bool
  if struct_update?(value) or yields_value?(resolved)
    return true
  end
  if !entry.ok?
    return false
  end
  found = entry.unwrap!
  return found.effects.size == 0 and !takes_function?(found) and !found.name.ends_with?("!")
end

def struct_update?(value: Ast.Expr) -> Bool
  case value
    Ast.Expr.Update(node) -> return true
    _ -> return false
  end
end

def yields_value?(resolved: Ast.Optional[State.Resolved]) -> Bool
  case resolved
    Ast.Optional.Present(found) -> return !resolved_is_call?(found)
    Ast.Optional.Absent -> return false
  end
end

def resolved_is_call?(found: State.Resolved) -> Bool
  case found
    State.Resolved.Call(name, receiver) -> return true
    _ -> return false
  end
end

def takes_function?(entry: Model.Builtin) -> Bool
  return entry.parameters.any? do |parameter: Model.Named| T.is(parameter.type, "Fn") end
end

def unused_subject(name: String) -> String
  if name == ""
    return "this expression"
  end
  return name
end

# The help of CHECK-UNUSED-VALUE: assign the result to the name the call was made on, when there is one.
def unused_help(value: Ast.Expr, resolved: Ast.Optional[State.Resolved], entry: Result[Model.Builtin]) -> String
  target = receiver_name(value)
  keeps = struct_update?(value) or resolved_self?(resolved) or (entry.ok? and keeps_first_type?(entry.unwrap!))
  if target != "" and keeps
    return "values are immutable, so this call changes nothing; assign the result, for example #{target} = ..."
  end
  return "values are immutable, so this call changes nothing; assign or use the result"
end

# The name a value is a call on, when the receiver is a plain name: xs in xs.push(1), xs.with(...) or List.append(xs,
# 1).
def receiver_name(value: Ast.Expr) -> String
  case value
    Ast.Expr.MethodCall(node) -> return name_of(node.target)
    Ast.Expr.FieldAccess(node) -> return name_of(node.target)
    Ast.Expr.Update(node) -> return name_of(node.target)
    Ast.Expr.Call(node) -> return first_argument_name(node.args)
    _ -> return ""
  end
end

def first_argument_name(args: List[Ast.Expr]) -> String
  if args.size == 0
    return ""
  end
  return name_of(args[0])
end

def name_of(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.Name(node) -> return node.name
    _ -> return ""
  end
end

def resolved_self?(resolved: Ast.Optional[State.Resolved]) -> Bool
  case resolved
    Ast.Optional.Present(found) -> return self_resolution?(found)
    Ast.Optional.Absent -> return false
  end
end

def self_resolution?(found: State.Resolved) -> Bool
  case found
    State.Resolved.Self(receiver) -> return true
    _ -> return false
  end
end

# True when the builtin returns the type of its first argument, so the call is a change of that value.
def keeps_first_type?(entry: Model.Builtin) -> Bool
  return entry.parameters.size > 0 and T.same(entry.parameters[0].type, entry.result)
end
