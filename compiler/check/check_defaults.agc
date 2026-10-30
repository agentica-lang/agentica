## The checks of default values, of parameters and of struct fields. The order and the shape of a default need no
## types, so they run when the function or struct is registered (CHECK-DEFAULT-ORDER, CHECK-DEFAULT-VALUE); the type of
## a default is checked with the function or in the order of the declarations, like an initializer
## (CHECK-TYPE-MISMATCH). A field default follows the rule of a parameter default, except the order: a constructor
## names its fields, so any field may have one.

import Model from "../catalog/builtin_model"
import Ast from "../syntax/ast"
import Types from "../syntax/types"
import State from "check_state"

## CHECK-DEFAULT-ORDER at the first parameter without a default that follows a parameter with one, unless it is the
## last and an Fn (the block of a call goes to it), and CHECK-DEFAULT-VALUE at the first default that is not a
## constant. Parameters are read in order, so the first problem found is the leftmost.
export def check_parameters(cx: State.Cx, st: State.St, node: Ast.FunctionDecl) -> Result[Bool]
  seen = false
  index = 0
  while index < node.params.size
    param = node.params[index]
    case param.default
      Ast.Maybe.Present(value) ->
        try check_value(cx, st, value, "make the parameter required")
        seen = true
      Ast.Maybe.Absent ->
        if seen and !(index == node.params.size - 1 and param.type.name == "Fn")
          return error(order_failure(cx, st, param))
        end
    end

    index += 1
  end

  return ok(true)
end

## Checks the default of each parameter against the parameter's type, in order. The types are recorded by node id, and
## the lowering reads them when it copies a default to a call site.
export def check_types(
  cx: State.Cx,
  st: State.St,
  node: Ast.FunctionDecl,
  types: List[Types.Type],
) -> Result[State.St]
  current = st
  index = 0
  while index < node.params.size
    case node.params[index].default
      Ast.Maybe.Present(value) ->
        out = try State.expr(cx, current, value, types[index])
        current = out.st
      Ast.Maybe.Absent -> current = current
    end

    index += 1
  end

  return ok(current)
end

## CHECK-DEFAULT-VALUE at the first field default that is not a constant.
export def check_field_value(cx: State.Cx, st: State.St, field: Ast.FieldDecl) -> Result[Bool]
  case field.default
    Ast.Maybe.Present(value) -> return check_value(cx, st, value, "remove the default")
    Ast.Maybe.Absent -> return ok(true)
  end
end

## Checks the default of each field of a registered struct against the field's type, in order, and records the types
## by node id like check_types.
export def check_field_types(cx: State.Cx, st: State.St, node: Ast.StructDecl) -> Result[State.St]
  types = cx.structs[node.name].map do |field: Model.Named| field.type end
  current = st
  index = 0
  while index < node.fields.size
    case node.fields[index].default
      Ast.Maybe.Present(value) ->
        out = try State.expr(cx, current, value, types[index])
        current = out.st
      Ast.Maybe.Absent -> current = current
    end

    index += 1
  end

  return ok(current)
end

def order_failure(cx: State.Cx, st: State.St, param: Ast.Param) -> String
  return State.fail_help(
    cx,
    st,
    "CHECK-DEFAULT-ORDER",
    "parameter \"#{param.name}\" has no default but follows a parameter with one",
    param.span,
    "give it a default, or move the parameters with a default to the end; only a last Fn parameter may have none",
  )
end

def check_value(cx: State.Cx, st: State.St, value: Ast.Expr, remedy: String) -> Result[Bool]
  if constant?(value)
    return ok(true)
  end

  return error(
    State.fail_help(
      cx,
      st,
      "CHECK-DEFAULT-VALUE",
      "a default value must be a constant",
      Ast.expr_span(value),
      "write a literal, true, false, nil, [], {} or an enum variant without a payload, or #{remedy}",
    ),
  )
end

# A literal (a minus sign allowed before a number), an empty list or map, or a variant with no payload: a value that
# the call site can build with no code of its own.
def constant?(value: Ast.Expr) -> Bool
  case value
    Ast.Expr.Literal(node) -> return true
    Ast.Expr.Unary(node) -> return node.op == "minus" and number?(node.operand)
    Ast.Expr.ListLit(node) -> return node.elements.size == 0
    Ast.Expr.MapLit(node) -> return node.entries.size == 0
    Ast.Expr.EnumConstructor(node) -> return node.args.size == 0 and node.named.size == 0
    _ -> return false
  end
end

def number?(value: Ast.Expr) -> Bool
  case value
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Whole(number) -> return true
        Ast.LitValue.Huge(digits) -> return true
        Ast.LitValue.Real(number) -> return true
        _ -> return false
      end

    _ -> return false
  end
end
