## How a call fills the parameters of a function that has default values (docs/grammar, "Default parameter values").
## The checker and the lowering share these rules, so the arguments the checker typed are the ones the lowering puts in
## the registers.
##
## Arguments fill the parameters from the left. When the last parameter is an Fn without a default that follows
## defaulted ones, the last argument (or the block) always goes to it, and the arguments before it fill the parameters
## from the left, so `each_line("a.txt") do |line| ... end` leaves the defaulted parameters between them alone.

import Model from "../catalog/builtin_model"
import Builtins from "../catalog/builtins"
import Ast from "../syntax/ast"

## What a call needs to know about a function: the fewest arguments it takes (required), all its parameters (total),
## and whether its last parameter is an Fn that takes the last argument (fn_last). A function with no default has
## required == total and fn_last false.
export struct Shape
  required: Int
  total: Int
  fn_last: Bool
end

## The shape of a form of a builtin, read from its parameters by the same rules. A builtin has no default after the
## first unless the last parameter is an Fn (Builtins.default_problem), so the shape is the one a function of the
## program with those defaults would have.
export def builtin_shape(form: Model.Builtin) -> Shape
  return Shape(
    required: Builtins.required_count(form),
    total: form.parameters.size,
    fn_last: Builtins.fn_last?(form),
  )
end

## The shape of a function, read from its parameters. The order of the defaults was checked before
## (CHECK-DEFAULT-ORDER), so a parameter without a default after a default can only be the last one, an Fn.
export def shape(params: List[Ast.Param]) -> Shape
  total = params.size
  first = total
  index = total - 1
  while index >= 0
    if default?(params[index])
      first = index
    end

    index -= 1
  end

  fn_last = first < total and !default?(params[total - 1])
  required = first
  if fn_last
    required = first + 1
  end

  return Shape(required: required, total: total, fn_last: fn_last)
end

## True when the function has a parameter with a default.
export def has_defaults?(shape: Shape) -> Bool
  return shape.required < shape.total
end

## The parameter that argument index fills in a call with count arguments.
export def param_of(shape: Shape, count: Int, index: Int) -> Int
  if shape.fn_last and index == count - 1
    return shape.total - 1
  end

  return index
end

## The argument that fills a parameter in a call with count arguments, or -1 when the default fills it.
export def argument_for(shape: Shape, count: Int, param: Int) -> Int
  if shape.fn_last and param == shape.total - 1
    return count - 1
  elsif shape.fn_last
    if param < count - 1
      return param
    end

    return -1
  end

  if param < count
    return param
  end

  return -1
end

## True when a struct field has a default value.
export def field_default?(field: Ast.FieldDecl) -> Bool
  case field.default
    Ast.Maybe.Present(value) -> return true
    Ast.Maybe.Absent -> return false
  end
end

def default?(param: Ast.Param) -> Bool
  case param.default
    Ast.Maybe.Present(value) -> return true
    Ast.Maybe.Absent -> return false
  end
end
