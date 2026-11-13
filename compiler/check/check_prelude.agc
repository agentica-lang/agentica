## The rule of a call of a prelude function (Rule.Prelude, docs/vm/03-ir-and-bytecode.md §4.7), such as xs.find
## do |x| ... end. The catalog row has the signature with type variables (A, B, K ...). The arguments are checked left
## to right: the receiver gives A, a block is checked with the parameter types the variables already have, and what the
## block gives binds the next variable. A variable the row limits (the key of group_by is an Int or a String) must end
## up as one of its allowed types. The checker records which function of stdlib/prelude/ the call runs, by the id of
## the call. A row may give defaults to its last parameters, as a Plain row does: the arguments fill the parameters
## by the rules of check/defaults.agc, and the lowering fills the rest. A block whose Result type is not known yet
## takes it from the expected type of the call, else from its body (Slot.InferResult), so `try` works in it (File.open
## with a block).

import Model from "../catalog/builtin_model"
import {PRELUDE} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import State from "check_state"
import Stmt from "check_stmt"
import CheckTypes from "check_types"
import Defaults from "defaults"

## Checks a call of a prelude builtin: the arguments against the parameters of the selected form, the limits of the
## row, and the type of the call, the result of the form with the variables filled in.
def check_prelude_call(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  form = site.selected
  row = PRELUDE[form.name]
  count = site.args.size
  shape = Defaults.builtin_shape(form)
  bound = Bound(st: st, types: {}, spans: {})
  index = 0
  while index < count
    param = Defaults.param_of(shape, site.node.slots, count, index)
    template = form.parameters[param].type
    settled = block_result(form, template, site.expected)
    bound = try check_argument(cx, bound, site.args[index], template, settled, row.module == "lazy")
    index += 1
  end

  try check_limits(cx, bound, form, row, site.node.span)
  found = bound.st.with(bodies: bound.st.bodies.put(site.node.id, body_of(row, bound.types)))
  ok(State.Out(st: found, type: CheckTypes.substitute(form.result, bound.types)))
end

private

# What the arguments checked so far learned: the state, the type of each variable and the span of the argument that
# bound it (the limits are reported there).
struct Bound
  st: State.St
  types: Map[String, T.Type]
  spans: Map[String, Source.Span]
end

# One argument: a block is checked with the parameter types known so far and the result the parameter says, any other
# expression with its parameter type when that is known. Then the type found is matched against the parameter, which
# binds the variables not seen yet. settled is the result an open block must give (block_result). step is true for a
# method of Lazy: a `try` in its block ends the pipeline.
def check_argument(
  cx: State.Cx,
  bound: Bound,
  arg: Ast.Expr,
  template: T.Type,
  settled: T.Type,
  step: Bool,
) -> Result[Bound]
  wanted = CheckTypes.substitute(template, bound.types)
  span = Ast.expr_span(arg)
  checked = State.Out(st: bound.st, type: T.Type.Unknown)
  case arg
    Ast.Expr.BlockLit(block) ->
      if T.is?(template, "Fn")
        checked = try check_block(cx, bound, block, template, settled, step)
      else
        checked = try State.expr(cx, bound.st, arg, T.Type.Unknown)
      end

    _ ->
      context = wanted
      if CheckTypes.open_variables?(template, bound.types)
        context = T.Type.Unknown
      end

      checked = try State.expr(cx, bound.st, arg, context)
  end

  fresh = free_variables(template).filter do |name: String| !bound.types.has_key?(name) end
  learned = try CheckTypes.unify(cx, checked.st, template, checked.type, bound.types, span)
  spans = bound.spans
  for name in fresh
    spans = spans.put(name, span)
  end

  ok(Bound(st: checked.st, types: learned, spans: spans))
end

# A block given for a parameter of type Fn[...]: its parameters are the types the Fn has, all known by now (the
# receiver comes first), and the result is the one the Fn has when that is known, else settled. "Known" is judged on
# the variables of the row (template), not on the types they stand for: in a generic function the type found may be
# the function's own type parameter.
def check_block(
  cx: State.Cx,
  bound: Bound,
  block: Ast.BlockLit,
  template: T.Type,
  settled: T.Type,
  step: Bool,
) -> Result[State.Out]
  params = CheckTypes.substitute_all(T.params(template), bound.types)
  if T.params(template).any? do |param: T.Type| CheckTypes.open_variables?(param, bound.types) end
    return error(
      State.fail(cx, bound.st, "CHECK-TYPE-MISMATCH", "the types of the block parameters are not known", block.span),
    )
  end

  result = CheckTypes.substitute(T.result(template), bound.types)
  if CheckTypes.open_variables?(T.result(template), bound.types)
    result = settled
  end

  Stmt.check_block_in(cx, bound.st, block, some(params), result, none, step)
end

# The result a block gives when its Fn's result still has an open variable. A Result there is one the body decides,
# Result[Unknown] (Slot.InferResult), unless it is also the call's result and the expected type of the call is a
# Result that names its item. Anything else is Unknown: the body decides it all.
def block_result(form: Model.Builtin, template: T.Type, expected: T.Type) -> T.Type
  return T.Type.Unknown if !T.is?(template, "Fn") or !T.is?(T.result(template), "Result")

  if T.same?(T.result(template), form.result) and T.is?(expected, "Result") and !T.unknown?(T.item(expected))
    return expected
  end

  T.Type.Result(T.Type.Unknown)
end

# CHECK-TYPE-MISMATCH at the argument that bound a limited variable to a type the row does not allow.
def check_limits(
  cx: State.Cx,
  bound: Bound,
  form: Model.Builtin,
  row: Model.PreludeRow,
  call: Source.Span,
) -> Result[Bool]
  for limit in row.limits
    found = bound.types.get(limit.variable)
    if found.none?
      return error(State.fail(cx, bound.st, "CHECK-TYPE-MISMATCH", "#{form.name} could not tell its types", call))
    end

    if limit.equality
      try check_equality(cx, bound, form, limit, found.unwrap!, call)
    elsif !limit.allowed.any? do |allowed: T.Type| T.same?(allowed, found.unwrap!) end
      names = limit.allowed.map do |allowed: T.Type| T.to_text(allowed) end
      options = names.take(names.size - 1).join(", ") + " or " + names[names.size - 1]
      return error(
        State.fail_help(
          cx,
          bound.st,
          "CHECK-TYPE-MISMATCH",
          "#{form.name} needs #{limit.what} of type #{options}, found #{T.to_text(found.unwrap!)}",
          bound.spans[limit.variable],
          "#{form.name} takes only these types here: #{options}",
        ),
      )
    end
  end

  ok(true)
end

# CHECK-TYPE-MISMATCH at the argument that bound an equality variable to a type that == does not compare.
def check_equality(
  cx: State.Cx,
  bound: Bound,
  form: Model.Builtin,
  limit: Model.Limit,
  found: T.Type,
  call: Source.Span,
) -> Result[Bool]
  return ok(true) if CheckTypes.equality?(cx, found)

  message = "#{form.name} needs #{limit.what} with equality, found #{T.to_text(found)}"
  why = CheckTypes.equality_gap(cx, found).why
  if why != ""
    message += ": #{why}"
  end

  error(
    State.fail_help(
      cx,
      bound.st,
      "CHECK-TYPE-MISMATCH",
      message,
      bound.spans[limit.variable],
      "#{form.name} compares with ==: numbers, Bool, String, nil, ranges, Bytes, and lists, maps, sets, Optionals, " +
      "Results, structs and enums of those",
    ),
  )
end

# The function of the prelude that runs, as "file::function": the one the row names for the type of its selector
# variable, else the one under "" (a row may name a faster body for a few types and a general one for the rest), or the
# only one.
def body_of(row: Model.PreludeRow, types: Map[String, T.Type]) -> String
  return "#{row.module}::#{row.bodies[""]}" if row.selector == ""

  tag = T.tag(types[row.selector])
  return "#{row.module}::#{row.bodies[""]}" if !row.bodies.has_key?(tag)

  "#{row.module}::#{row.bodies[tag]}"
end

# The type variables written in a type.
def free_variables(type: T.Type) -> List[String]
  case type
    T.Type.Var(name) -> [name]
    T.Type.Result(item) -> free_variables(item)
    T.Type.Optional(item) -> free_variables(item)
    T.Type.Task(item) -> free_variables(item)
    T.Type.Channel(item) -> free_variables(item)
    T.Type.Address(item) -> free_variables(item)
    T.Type.Lazy(item) -> free_variables(item)
    T.Type.Codec(item) -> free_variables(item)
    T.Type.List(item) -> free_variables(item)
    T.Type.Set(item) -> free_variables(item)
    T.Type.Map(key, value) -> free_variables(key).concat(free_variables(value))
    T.Type.ATS(key, value) -> free_variables(key).concat(free_variables(value))
    T.Type.Fn(params, result) -> free_variables_of(params).concat(free_variables(result))
    T.Type.Enum(_, args) -> free_variables_of(args)
    _ -> []
  end
end

def free_variables_of(types: List[T.Type]) -> List[String]
  names: List[String] = []
  for type in types
    names = names.concat(free_variables(type))
  end

  names
end
