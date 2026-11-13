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

## How the arguments of a call with named arguments fill the parameters: slots, the parameter of each argument in
## source order (Ast.Call.slots), or the first problem. code is "" when the call binds, else CHECK-UNKNOWN-ARGUMENT,
## CHECK-REPEATED-ARGUMENT (at the named argument `at`), CHECK-MISSING-ARGUMENT (the parameter `name` has no default
## and no argument) or CHECK-ARITY (more positional arguments than parameters); at is -1 for a problem of the whole
## call.
export struct Binding
  slots: List[Int]
  code: String
  at: Int
  name: String
end

## The shape of a form of a builtin, read from its parameters by the same rules. A builtin has no default after the
## first unless the last parameter is an Fn (Builtins.default_problem), so the shape is the one a function of the
## program with those defaults would have.
export def builtin_shape(form: Model.Builtin) -> Shape
  Shape(required: Builtins.required_count(form), total: form.parameters.size, fn_last: Builtins.fn_last?(form))
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

  Shape(required: required, total: total, fn_last: fn_last)
end

## True when the function has a parameter with a default.
export def has_defaults?(shape: Shape) -> Bool = shape.required < shape.total

## The parameter that argument index fills in a call with count arguments. slots is the parameter of each argument of a
## call with named arguments (Ast.Call.slots), empty for the positional rule.
export def param_of(shape: Shape, slots: List[Int], count: Int, index: Int) -> Int
  return slots[index] if slots.size > 0

  return shape.total - 1 if shape.fn_last and index == count - 1

  index
end

## The argument that fills a parameter in a call with count arguments, or -1 when the default fills it. slots as for
## param_of.
export def argument_for(shape: Shape, slots: List[Int], count: Int, param: Int) -> Int
  return slot_of(slots, param) if slots.size > 0

  if shape.fn_last and param == shape.total - 1
    return count - 1
  elsif shape.fn_last
    return param if param < count - 1

    return -1
  end

  return param if param < count

  -1
end

## Binds the arguments of a call to the parameters called `names`. The positional arguments fill the parameters from
## the left and each named one the parameter of its name. A trailing block fills the last parameter when it is an Fn
## that follows defaults (Shape.fn_last), as in a positional call; otherwise the first parameter that no other
## argument fills, which is the next one in a positional call (`reduce(initial: 0) do ... end` gives the block to the
## Fn after `initial`). A parameter named `_` has no name.
export def bind(names: List[String], shape: Shape, args: List[Ast.Expr], named: List[Ast.NamedArg]) -> Binding
  block = trailing_block?(args)
  positional = args.size
  if block
    positional -= 1
  end

  if positional > shape.total or (block and shape.fn_last and positional >= shape.total)
    return Binding(slots: [], code: "CHECK-ARITY", at: -1, name: "")
  end

  filled: List[Bool] = []
  for param in 0...shape.total
    filled = filled.push(param < positional or (block and shape.fn_last and param == shape.total - 1))
  end

  slots: List[Int] = []
  for param in 0...positional
    slots = slots.push(param)
  end

  at = 0
  while at < named.size
    param = parameter_named(names, named[at].name)
    return Binding(slots: [], code: "CHECK-UNKNOWN-ARGUMENT", at: at, name: "") if param < 0

    return Binding(slots: [], code: "CHECK-REPEATED-ARGUMENT", at: at, name: "") if filled[param]

    filled = filled.set(param, true)
    slots = slots.push(param)
    at += 1
  end

  block_slot = shape.total - 1
  if block and !shape.fn_last
    block_slot = first_open(filled)
    return Binding(slots: [], code: "CHECK-ARITY", at: -1, name: "") if block_slot < 0

    filled = filled.set(block_slot, true)
  end

  if block
    slots = slots.push(block_slot)
  end

  for param in 0...shape.total
    if !filled[param] and !defaulted?(shape, param)
      return Binding(slots: [], code: "CHECK-MISSING-ARGUMENT", at: -1, name: names[param])
    end
  end

  Binding(slots: slots, code: "", at: -1, name: "")
end

## The arguments of a call in source order: the positional ones, then the named values, then a trailing block (which
## the parser keeps as the last of args).
export def arguments(args: List[Ast.Expr], named: List[Ast.NamedArg]) -> List[Ast.Expr]
  values = named.map do |arg: Ast.NamedArg| arg.value end
  return args.concat(values) if !trailing_block?(args)

  last = args.size - 1
  args.take(last).concat(values).push(args[last])
end

## The call with its named arguments bound: args in source order, named empty and slots set.
export def bound(node: Ast.Call, slots: List[Int]) -> Ast.Call
  no_named: List[Ast.NamedArg] = []
  node.with(args: arguments(node.args, node.named), named: no_named, slots: slots)
end

## A bound call with every parameter given, as the positional call with its arguments in parameter order. It is for the
## builtin rules that read the arguments by position; the lowering still runs them in source order.
export def in_parameter_order(node: Ast.Call) -> Ast.Call
  return node if node.slots.size == 0

  args: List[Ast.Expr] = []
  for param in 0...node.slots.size
    args = args.push(node.args[slot_of(node.slots, param)])
  end

  no_slots: List[Int] = []
  node.with(args: args, slots: no_slots)
end

## True when the last argument is a `do` or `{ }` block written after the call.
export def trailing_block?(args: List[Ast.Expr]) -> Bool
  return false if args.size == 0

  case args[args.size - 1]
    Ast.Expr.BlockLit(block) -> !block.lambda
    _ -> false
  end
end

## True when a struct field has a default value.
export def field_default?(field: Ast.FieldDecl) -> Bool = field.default.some?

# The first parameter that no argument fills, or -1.
def first_open(filled: List[Bool]) -> Int
  index = 0
  while index < filled.size
    return index if !filled[index]

    index += 1
  end

  -1
end

# The argument that fills param, or -1.
def slot_of(slots: List[Int], param: Int) -> Int
  index = 0
  while index < slots.size
    return index if slots[index] == param

    index += 1
  end

  -1
end

# The index of the parameter called name, or -1.
def parameter_named(names: List[String], name: String) -> Int
  return -1 if name == "_"

  index = 0
  while index < names.size
    return index if names[index] == name

    index += 1
  end

  -1
end

# True when the parameter has a default value: from the first default on, except an Fn last that takes the block.
def defaulted?(shape: Shape, param: Int) -> Bool
  first = shape.required
  if shape.fn_last
    first -= 1
  end

  param >= first and !(shape.fn_last and param == shape.total - 1)
end

def default?(param: Ast.Param) -> Bool = param.default.some?
