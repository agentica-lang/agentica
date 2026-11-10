## CHECK-UNUSED-RESULT: a Result that is dropped loses its error. CHECK-UNUSED-VALUE: a value that is dropped, and
## could only have been used for itself, is an error.

import Model from "../catalog/builtin_model"
import {ENTRIES} from "../catalog/builtins"
import Ast from "../syntax/ast"
import T from "../syntax/types"
import State from "check_state"

# The longest text of a value that a help copies; a longer or multi-line one is written as `...`.
MAX_VALUE_TEXT = 60

## CHECK-UNUSED-RESULT when the dropped value is a Result, from any call (a Result[Void] too); it runs first, so a pure
## builtin that gives a Result, such as s.to_i, is this error and not CHECK-UNUSED-VALUE. Then CHECK-UNUSED-VALUE when
## the value could only have been used for itself: a pure builtin, a to_s on a data value, a .with. Anything else, and
## any Void value, is fine.
export def check_unused_value(cx: State.Cx, st: State.St, value: Ast.Expr, type: T.Type) -> Result[Bool]
  return ok(true) if T.is?(type, "Void")

  resolved = resolution(st, value)
  name = call_name(value, resolved)
  # IO.inspect prints its argument and gives it back, so a Result it returns was already shown, and nothing is lost.
  if T.is?(type, "Result") and name != "IO.inspect"
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNUSED-RESULT",
        "the Result of #{unused_subject(name)} is not used, so its error is lost",
        Ast.expr_span(value),
        handle_result_help(value_text(cx, value), State.try_allowed?(st)),
      ),
    )
  end

  entry = ENTRIES.get(name)
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

## How to handle a Result that is not used: `try` where it is allowed, a `case`, `.unwrap!`, or the discard `_ =`. The
## help of CHECK-UNUSED-RESULT and of CHECK-UNUSED-VARIABLE share it; `text` is the source of the call.
export def handle_result_help(text: String, tryable: Bool) -> String
  attempt = ""
  if tryable
    attempt = "try #{text}, "
  end

  return (
    "handle the Result: #{attempt}a case on ok(_) and error(message), or .unwrap!; " +
    "or discard it with _ = #{text}"
  )
end

## The source text of the expression, or `...` when it is long or spans lines.
export def value_text(cx: State.Cx, value: Ast.Expr) -> String
  span = Ast.expr_span(value)
  text = cx.texts.get(cx.file).unwrap_or("").slice(span.start.offset, span.stop.offset - span.start.offset)
  return "..." if text.length > MAX_VALUE_TEXT or text.contains?("\n")

  return text
end

# What a method call or field access resolved to; `none` for any other expression.
def resolution(st: State.St, value: Ast.Expr) -> Optional[State.Resolved]
  case value
    Ast.Expr.MethodCall(node) -> return found_resolution(st, node.id)
    Ast.Expr.FieldAccess(node) -> return found_resolution(st, node.id)
    _ -> return none
  end
end

def found_resolution(st: State.St, id: Int) -> Optional[State.Resolved]
  return st.resolved.get(id)
end

# The builtin a dropped value calls: the one a method resolved to, or a call written by name. "" for anything else.
def call_name(value: Ast.Expr, resolved: Optional[State.Resolved]) -> String
  case resolved
    some(found) -> return resolved_call_name(found)
    none -> return plain_call_name(value)
  end
end

def resolved_call_name(found: State.Resolved) -> String
  case found
    State.Resolved.Call(name, _) -> return name
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
def unused_result?(value: Ast.Expr, resolved: Optional[State.Resolved], entry: Optional[Model.Builtin]) -> Bool
  return true if struct_update?(value) or yields_value?(resolved)

  return false if entry.none?

  found = entry.unwrap!
  return found.effects.size == 0 and !takes_function?(found) and !found.name.ends_with?("!")
end

def struct_update?(value: Ast.Expr) -> Bool
  case value
    Ast.Expr.Update(_) -> return true
    _ -> return false
  end
end

def yields_value?(resolved: Optional[State.Resolved]) -> Bool
  case resolved
    some(found) -> return !resolved_is_call?(found)
    none -> return false
  end
end

def resolved_is_call?(found: State.Resolved) -> Bool
  case found
    State.Resolved.Call(_, _) -> return true
    State.Resolved.FieldCall -> return true
    _ -> return false
  end
end

def takes_function?(entry: Model.Builtin) -> Bool
  return entry.parameters.any? do |parameter: Model.Named| T.is?(parameter.type, "Fn") end
end

# The name of the call for a message. The linker names a call into another module `@3::save`: only `save` is shown.
def unused_subject(name: String) -> String
  return "this expression" if name == ""

  return name.split("::").last if name.starts_with?("@") and name.contains?("::")

  return name
end

# The help of CHECK-UNUSED-VALUE: assign the result to the name the call was made on, when there is one.
def unused_help(value: Ast.Expr, resolved: Optional[State.Resolved], entry: Optional[Model.Builtin]) -> String
  target = receiver_name(value)
  keeps = struct_update?(value) or resolved_self?(resolved) or (entry.some? and keeps_first_type?(entry.unwrap!))
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
  return "" if args.size == 0

  return name_of(args[0])
end

def name_of(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.Name(node) -> return node.name
    _ -> return ""
  end
end

def resolved_self?(resolved: Optional[State.Resolved]) -> Bool
  case resolved
    some(found) -> return self_resolution?(found)
    none -> return false
  end
end

def self_resolution?(found: State.Resolved) -> Bool
  case found
    State.Resolved.Self(_) -> return true
    _ -> return false
  end
end

# True when the builtin returns the type of its first argument, so the call is a change of that value.
def keeps_first_type?(entry: Model.Builtin) -> Bool
  return entry.parameters.size > 0 and T.same?(entry.parameters[0].type, entry.result)
end
