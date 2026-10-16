## The checking rules of the List builtins. A rule
## takes the call (State.Site) and returns the new state with the type of the call.

import Ast from "ast"
import Model from "builtin_model"
import Args from "check_args"
import State from "check_state"
import Stmt from "check_stmt"
import CheckTypes from "check_types"
import Source from "source"
import T from "types"

## Checks a call of a List builtin by its rule. Any other rule is the caller's.
export def check_list_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.ListSize ->
      out = try Args.list_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: out.st, type: T.Type.Int))
    Model.Rule.ListReverse -> return Args.list_argument(cx, st, site, T.only_list(site.expected))
    Model.Rule.ListSort -> return check_sort(cx, st, site)
    Model.Rule.ListSortBy -> return check_sort_by(cx, st, site)
    Model.Rule.ListConcat -> return check_concat(cx, st, site)
    Model.Rule.ListCount -> return check_count(cx, st, site, false)
    Model.Rule.ListAt -> return check_count(cx, st, site, true)
    Model.Rule.ListAppend -> return check_append(cx, st, site, false)
    Model.Rule.ListSet -> return check_append(cx, st, site, true)
    Model.Rule.ListRepeat -> return check_repeat(cx, st, site)
    _ -> return check_callback_rule(cx, st, site, rule)
  end
end

# List.sort: a list of Int, Float or String.
def check_sort(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.list_argument(cx, st, site, T.only_list(site.expected))
  element = T.item(target.type)
  if !T.is(element, "Int") and !T.is(element, "Float") and !T.is(element, "String")
    return error(
      State.fail(
        cx,
        target.st,
        "CHECK-TYPE-MISMATCH",
        "List.sort needs List[Int], List[Float] or List[String], found #{T.to_text(target.type)}",
        Ast.expr_span(site.args[0]),
      ),
    )
  end
  return ok(target)
end

# List.sort_by: the key function is a block (which gives the element type of the list) or a function value.
def check_sort_by(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  callback = site.args[1]
  case callback
    Ast.Expr.BlockLit(block) -> return sort_by_block(cx, st, site, block)
    _ -> return sort_by_function(cx, st, site, callback)
  end
end

def sort_by_block(cx: State.Cx, st: State.St, site: State.Site, block: Ast.BlockLit) -> Result[State.Out]
  annotated = try annotated_parameter(cx, st, block, 0)
  target = try Args.list_argument(cx, st, site, T.list_of(annotated))
  key = try Stmt.check_block_body(
    cx,
    target.st,
    block,
    Ast.Optional.Present([T.item(target.type)]),
    T.Type.Unknown,
    Ast.Optional.Absent,
  )
  try check_sort_key(cx, key.st, key.type, block.span)
  return ok(State.Out(st: key.st, type: target.type))
end

def sort_by_function(cx: State.Cx, st: State.St, site: State.Site, callback: Ast.Expr) -> Result[State.Out]
  key = try State.expr(cx, st, callback, T.Type.Unknown)
  try check_sort_key(cx, key.st, key.type, Ast.expr_span(callback))
  return Args.list_argument(cx, key.st, site, T.Type.List(T.params(key.type)[0]))
end

# The key function takes one parameter and gives an Int, a Float or a String.
def check_sort_key(cx: State.Cx, st: State.St, callback: T.Type, span: Source.Span) -> Result[Bool]
  if !T.is(callback, "Fn") or T.params(callback).size != 1
    return error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", "sort_by requires a key function with one parameter", span))
  end
  key = T.result(callback)
  if !T.is(key, "Int") and !T.is(key, "Float") and !T.is(key, "String")
    return error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", "sort_by keys must be Int, Float or String", span))
  end
  return ok(true)
end

# List.concat: both lists have one type; an empty literal takes the type of the other side.
def check_concat(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  context = T.only_list(site.expected)
  current = st
  if T.unknown?(context) and Args.empty_list?(site.args[0])
    other = try State.expr(cx, current, site.args[1], T.Type.Unknown)
    current = other.st
    context = other.type
  end
  target = try Args.list_argument(cx, current, site, context)
  second = try State.expr(cx, target.st, site.args[1], target.type)
  return ok(State.Out(st: second.st, type: target.type))
end

# List.take, List.drop and List.at: a list and an Int; at gives the element.
def check_count(cx: State.Cx, st: State.St, site: State.Site, at: Bool) -> Result[State.Out]
  context = T.only_list(site.expected)
  if at
    context = T.list_of(site.expected)
  end
  target = try Args.list_argument(cx, st, site, context)
  count = try State.expr(cx, target.st, site.args[1], T.Type.Int)
  if at
    return ok(State.Out(st: count.st, type: T.item(target.type)))
  end
  return ok(State.Out(st: count.st, type: target.type))
end

# List.append and List.set: the value has the element type; an empty literal takes it from the value.
def check_append(cx: State.Cx, st: State.St, site: State.Site, set: Bool) -> Result[State.Out]
  value = site.args[site.args.size - 1]
  context = T.only_list(site.expected)
  current = st
  if T.unknown?(context) and Args.empty_list?(site.args[0])
    first = try State.expr(cx, current, value, T.Type.Unknown)
    current = first.st
    context = T.Type.List(first.type)
  end
  target = try Args.list_argument(cx, current, site, context)
  current = target.st
  if set
    index = try State.expr(cx, current, site.args[1], T.Type.Int)
    current = index.st
  end
  checked = try State.expr(cx, current, value, T.item(target.type))
  return ok(State.Out(st: checked.st, type: target.type))
end

def check_repeat(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  context = T.Type.Unknown
  if T.is(site.expected, "List")
    context = T.item(site.expected)
  end
  element = try State.expr(cx, st, site.args[0], context)
  count = try State.expr(cx, element.st, site.args[1], T.Type.Int)
  return ok(State.Out(st: count.st, type: T.Type.List(element.type)))
end

# The type written on parameter number index of a block, or Unknown when it has none.
def annotated_parameter(cx: State.Cx, st: State.St, block: Ast.BlockLit, index: Int) -> Result[T.Type]
  if block.params.size <= index
    return ok(T.Type.Unknown)
  end
  case block.params[index].type
    Ast.Optional.Present(annotation) -> return CheckTypes.resolve_type(cx, st, annotation, false)
    Ast.Optional.Absent -> return ok(T.Type.Unknown)
  end
end

# List.map, filter, reduce, each, any? and all?: the callback is a block (which gets the element type) or a function
# value.
def check_callback_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  callback = site.args[site.args.size - 1]
  checked = State.Out(st: st, type: T.Type.Unknown)
  case callback
    Ast.Expr.BlockLit(block) -> checked = try block_callback(cx, st, site, rule, block)
    _ -> checked = try State.expr(cx, st, callback, T.Type.Unknown)
  end
  arity = 1
  if reduces?(rule)
    arity = 2
  end
  if !T.is(checked.type, "Fn") or T.params(checked.type).size != arity
    return error(
      State.fail(cx, checked.st, "CHECK-TYPE-MISMATCH", "wrong collection callback type", Ast.expr_span(callback)),
    )
  end
  return callback_result(cx, checked.st, site, rule, callback, checked.type)
end

# The callback of a block: the list gives the element type, and the rule gives the parameters and result the block must
# have.
def block_callback(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  rule: Model.Rule,
  block: Ast.BlockLit,
) -> Result[State.Out]
  position = 0
  if reduces?(rule)
    position = 1
  end
  annotated = try annotated_parameter(cx, st, block, position)
  list = try Args.list_argument(cx, st, site, T.list_of(annotated))
  element = T.item(list.type)
  receiver: Ast.Optional[Ast.Expr] = Ast.Optional.Absent
  if each?(rule)
    receiver = Ast.Optional.Present(site.args[0])
  end
  if reduces?(rule)
    return reduce_block(cx, list.st, site, block, element)
  end
  return Stmt.check_block_body(cx, list.st, block, Ast.Optional.Present([element]), block_result(rule), receiver)
end

def reduce_block(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  block: Ast.BlockLit,
  element: T.Type,
) -> Result[State.Out]
  start = site.expected
  if T.unknown?(start)
    start = try annotated_parameter(cx, st, block, 0)
  end
  accumulator = try State.expr(cx, st, site.args[1], start)
  return Stmt.check_block_body(
    cx,
    accumulator.st,
    block,
    Ast.Optional.Present([accumulator.type, element]),
    accumulator.type,
    Ast.Optional.Absent,
  )
end

# The result a block of the rule must give: Bool for filter, any? and all?, Void for each, none known for map.
def block_result(rule: Model.Rule) -> T.Type
  case rule
    Model.Rule.ListFilter -> return T.Type.Bool
    Model.Rule.ListAny -> return T.Type.Bool
    Model.Rule.ListAll -> return T.Type.Bool
    Model.Rule.ListEach -> return T.Type.Void
    _ -> return T.Type.Unknown
  end
end

def reduces?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.ListReduce -> return true
    _ -> return false
  end
end

def each?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.ListEach -> return true
    _ -> return false
  end
end

# The type of the call once the callback is checked: the list is checked against the element type of a function value,
# then the result follows from the rule.
def callback_result(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  rule: Model.Rule,
  callback: Ast.Expr,
  type: T.Type,
) -> Result[State.Out]
  span = Ast.expr_span(callback)
  params = T.params(type)
  result = T.result(type)
  element = params[0]
  if reduces?(rule)
    element = params[1]
  end
  current = st
  if !is_block?(callback)
    list = try Args.list_argument(cx, current, site, T.Type.List(element))
    current = list.st
  end
  if reduces?(rule)
    return reduce_result(cx, current, site, callback, params[0], result)
  end
  return plain_result(cx, current, rule, span, element, result)
end

def reduce_result(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  callback: Ast.Expr,
  accumulator: T.Type,
  result: T.Type,
) -> Result[State.Out]
  span = Ast.expr_span(callback)
  if !T.same(accumulator, result)
    return error(State.mismatch(cx, st, accumulator, result, span))
  end
  current = st
  if !is_block?(callback)
    initial = try State.expr(cx, current, site.args[1], result)
    current = initial.st
  end
  return ok(State.Out(st: current, type: result))
end

def plain_result(
  cx: State.Cx,
  st: State.St,
  rule: Model.Rule,
  span: Source.Span,
  element: T.Type,
  result: T.Type,
) -> Result[State.Out]
  case rule
    Model.Rule.ListFilter ->
      try require_type(cx, st, T.Type.Bool, result, span)
      return ok(State.Out(st: st, type: T.Type.List(element)))
    Model.Rule.ListAny ->
      try require_type(cx, st, T.Type.Bool, result, span)
      return ok(State.Out(st: st, type: T.Type.Bool))
    Model.Rule.ListAll ->
      try require_type(cx, st, T.Type.Bool, result, span)
      return ok(State.Out(st: st, type: T.Type.Bool))
    Model.Rule.ListEach ->
      try require_type(cx, st, T.Type.Void, result, span)
      return ok(State.Out(st: st, type: T.Type.Void))
    _ -> return map_result(cx, st, span, result)
  end
end

def map_result(cx: State.Cx, st: State.St, span: Source.Span, result: T.Type) -> Result[State.Out]
  if T.is(result, "Void")
    return error(State.fail(cx, st, "CHECK-VOID-VALUE", "map callbacks must return data", span))
  end
  return ok(State.Out(st: st, type: T.Type.List(result)))
end

def require_type(cx: State.Cx, st: State.St, expected: T.Type, actual: T.Type, span: Source.Span) -> Result[Bool]
  if !T.same(expected, actual)
    return error(State.mismatch(cx, st, expected, actual, span))
  end
  return ok(true)
end

def is_block?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.BlockLit(block) -> return true
    _ -> return false
  end
end
