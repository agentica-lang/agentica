## The rule of a call of a prelude function (Rule.Prelude, docs/future/25-ruby-typed-idioms.md 25.6), such as xs.find
## do |x| ... end. The catalog row has the signature with type variables (A, B, K ...). The arguments are checked left
## to right: the receiver gives A, a block is checked with the parameter types the variables already have, and what the
## block gives binds the next variable. A variable the row limits (the key of group_by is an Int or a String) must end
## up as one of its allowed types. The checker records which function of stdlib/prelude/ the call runs, by the id of
## the call. A row may give defaults to its last parameters, as a Plain row does: the arguments fill the parameters
## by the rules of check/defaults.agc, and the lowering fills the rest.

import Model from "../catalog/builtin_model"
import {PRELUDE} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import State from "check_state"
import Stmt from "check_stmt"
import CheckTypes from "check_types"
import Defaults from "defaults"

# What the arguments checked so far learned: the state, the type of each variable and the span of the argument that
# bound it (the limits are reported there).
struct Bound
  st: State.St
  types: Map[String, T.Type]
  spans: Map[String, Source.Span]
end

## Checks a call of a prelude builtin: the arguments against the parameters of the selected form, the limits of the
## row, and the type of the call, the result of the form with the variables filled in.
export def check_prelude_call(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  form = site.selected
  row = PRELUDE[form.name]
  count = site.args.size
  shape = Defaults.builtin_shape(form)
  bound = Bound(st: st, types: {}, spans: {})
  index = 0
  while index < count
    param = Defaults.param_of(shape, count, index)
    bound = try check_argument(cx, bound, site.args[index], form.parameters[param].type, row.module == "lazy")
    index += 1
  end

  try check_limits(cx, bound, form, row, site.node.span)
  found = bound.st.with(bodies: bound.st.bodies.put(site.node.id, body_of(row, bound.types)))
  return ok(State.Out(st: found, type: CheckTypes.substitute(form.result, bound.types)))
end

# One argument: a block is checked with the parameter types known so far and the result the parameter says, any other
# expression with its parameter type when that is known. Then the type found is matched against the parameter, which
# binds the variables not seen yet. step is true for a method of Lazy: a `try` in its block ends the pipeline.
def check_argument(cx: State.Cx, bound: Bound, arg: Ast.Expr, template: T.Type, step: Bool) -> Result[Bound]
  wanted = CheckTypes.substitute(template, bound.types)
  span = Ast.expr_span(arg)
  checked = State.Out(st: bound.st, type: T.Type.Unknown)
  case arg
    Ast.Expr.BlockLit(block) ->
      if T.is?(template, "Fn")
        checked = try check_block(cx, bound, block, template, step)
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

  return ok(Bound(st: checked.st, types: learned, spans: spans))
end

# A block given for a parameter of type Fn[...]: its parameters are the types the Fn has, all known by now (the
# receiver comes first), and the result is the one the Fn has when that is known. "Known" is judged on the variables of
# the row (template), not on the types they stand for: in a generic function the type found may be the function's own
# type parameter.
def check_block(cx: State.Cx, bound: Bound, block: Ast.BlockLit, template: T.Type, step: Bool) -> Result[State.Out]
  params = CheckTypes.substitute_all(T.params(template), bound.types)
  if T.params(template).any? do |param: T.Type| CheckTypes.open_variables?(param, bound.types) end
    return error(
      State.fail(cx, bound.st, "CHECK-TYPE-MISMATCH", "the types of the block parameters are not known", block.span),
    )
  end

  result = CheckTypes.substitute(T.result(template), bound.types)
  if CheckTypes.open_variables?(T.result(template), bound.types)
    result = T.Type.Unknown
  end

  return Stmt.check_block_in(cx, bound.st, block, some(params), result, none, step)
end

# CHECK-TYPE-MISMATCH at the argument that bound a limited variable to a type the row does not allow.
def check_limits(
  cx: State.Cx, bound: Bound, form: Model.Builtin, row: Model.PreludeRow, call: Source.Span
) -> Result[Bool]
  for limit in row.limits
    found = bound.types.get(limit.variable)
    if found.none?
      return error(
        State.fail(cx, bound.st, "CHECK-TYPE-MISMATCH", "#{form.name} could not tell its types", call),
      )
    end

    if !limit.allowed.any? do |allowed: T.Type| T.same?(allowed, found.unwrap!) end
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

  return ok(true)
end

# The function of the prelude that runs, as "file::function": the one the row names for the type of its selector
# variable, or the only one.
def body_of(row: Model.PreludeRow, types: Map[String, T.Type]) -> String
  if row.selector == ""
    return "#{row.module}::#{row.bodies[""]}"
  end

  return "#{row.module}::#{row.bodies[T.tag(types[row.selector])]}"
end

# The type variables written in a type.
def free_variables(type: T.Type) -> List[String]
  case type
    T.Type.Var(name) -> return [name]
    T.Type.Result(item) -> return free_variables(item)
    T.Type.Optional(item) -> return free_variables(item)
    T.Type.Task(item) -> return free_variables(item)
    T.Type.Channel(item) -> return free_variables(item)
    T.Type.Lazy(item) -> return free_variables(item)
    T.Type.Codec(item) -> return free_variables(item)
    T.Type.List(item) -> return free_variables(item)
    T.Type.Set(item) -> return free_variables(item)
    T.Type.Map(key, value) -> return free_variables(key).concat(free_variables(value))
    T.Type.ATS(key, value) -> return free_variables(key).concat(free_variables(value))
    T.Type.Fn(params, result) -> return free_variables_of(params).concat(free_variables(result))
    T.Type.Enum(name, args) -> return free_variables_of(args)
    _ -> return []
  end
end

def free_variables_of(types: List[T.Type]) -> List[String]
  names: List[String] = []
  for type in types
    names = names.concat(free_variables(type))
  end

  return names
end
