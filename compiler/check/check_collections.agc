## The checking rules of the Map, Set, Task, Channel, ATS, Profile and Native builtins. A rule takes the call
## (State.Site) and returns the new state with the type of the call.

import Model from "../catalog/builtin_model"
import {HANDLES} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import Args from "check_args"
import Lists from "check_list"
import State from "check_state"
import Stmt from "check_stmt"
import CheckTypes from "check_types"

## Checks a call of a Task, Channel, Map, Set, Profile or Native builtin by its rule. Any other rule is the caller's.
export def check_collection_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.TaskSpawn -> return check_spawn(cx, st, site, false)
    Model.Rule.TaskSpawnOwning -> return check_spawn(cx, st, site, true)
    Model.Rule.NativeClose -> return check_native_target(cx, st, site, false)
    Model.Rule.NativeClosed -> return check_native_target(cx, st, site, true)
    Model.Rule.TaskAwait -> return check_await(cx, st, site)
    Model.Rule.TaskAwaitTimeout -> return check_await_timeout(cx, st, site)
    Model.Rule.TaskMap -> return check_task_map(cx, st, site)
    Model.Rule.TaskTarget -> return check_target(cx, st, site, &Args.task_argument)
    Model.Rule.AtsNew -> return check_ats_new(cx, st, site)
    Model.Rule.AtsCall -> return check_ats_call(cx, st, site)
    Model.Rule.ChannelNew -> return check_channel_new(cx, st, site)
    Model.Rule.ChannelSend -> return check_channel_send(cx, st, site)
    Model.Rule.ChannelRecv -> return check_channel_recv(cx, st, site)
    Model.Rule.ChannelTarget -> return check_target(cx, st, site, &Args.channel_argument)
    Model.Rule.ProfileMeasure -> return check_block_value(cx, st, site, T.Type.String, [])
    Model.Rule.NativeMemoryBlock ->
      first = site.selected.parameters[0].type
      return check_block_value(cx, st, site, first, [T.Type.Opaque("C.Pointer")])
    Model.Rule.NativeStruct -> return check_native_struct(cx, st, site)
    Model.Rule.NativeCallback -> return check_native_callback(cx, st, site)
    _ -> return check_map_rule(cx, st, site, rule)
  end
end

## True for a type that holds a JSON.Codec somewhere, walked as holds_handle? walks: IO.inspect refuses it, since a
## codec is the name of its struct at run time and would print as that String.
export def holds_codec?(cx: State.Cx, type: T.Type) -> Bool
  return holds?(cx, type) do |part: T.Type| T.is?(part, "Codec") end
end

# Task.spawn and Task.spawn_owning: a function of one parameter and the argument it gets; Task.spawn alone also has
# the form with no argument, for a function of no parameter. The owning form also hands over a handle, a channel or
# an owned buffer (a C.Pointer, whose ownership the VM checks: one that C gave is RUNTIME-HANDLE-NOT-OWNED), or every
# one of them that a struct, enum, List, Map or Result holds.
def check_spawn(cx: State.Cx, st: State.St, site: State.Site, owning: Bool) -> Result[State.Out]
  callback = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  wanted = site.args.size - 1
  if !T.is?(callback.type, "Fn") or T.params(callback.type).size != wanted
    return error(spawn_mismatch(cx, callback, site, owning, wanted))
  end

  if wanted == 0
    return ok(State.Out(st: callback.st, type: T.Type.Task(T.result(callback.type))))
  end

  handed = try State.expr(cx, callback.st, site.args[1], T.params(callback.type)[0])
  if owning and !holds_handle?(cx, handed.type)
    return error(
      State.fail_help(
        cx,
        handed.st,
        "CHECK-NOT-A-HANDLE",
        "Task.spawn_owning gives a handle to the new task, but the argument is #{T.to_text(handed.type)}",
        Ast.expr_span(site.args[1]),
        "pass a FileHandle, Socket, Listener, Process, HttpServer, Channel, resource or owned buffer, or a value " +
        "that holds one; Task.spawn passes any other value",
      ),
    )
  end

  return ok(State.Out(st: handed.st, type: T.Type.Task(T.result(callback.type))))
end

# CHECK-TYPE-MISMATCH of a spawn whose function does not take as many parameters as the call has arguments after it.
# The 0-argument form belongs to Task.spawn alone. A one-parameter function without its argument gets a help.
def spawn_mismatch(cx: State.Cx, callback: State.Out, site: State.Site, owning: Bool, wanted: Int) -> String
  needs = "Task.spawn(&f) needs 0 parameters, Task.spawn(&f, arg) needs 1, a block needs 0: Task.spawn do ... end"
  if owning
    needs = "Task.spawn_owning(&f, handle) needs 1 parameter"
  end

  message = (
    "#{site.selected.name} expects a function that takes #{wanted} parameter(s), " +
    "found #{spawn_found(callback.type)}; #{needs}"
  )
  span = Ast.expr_span(site.args[0])
  if wanted == 0 and T.is?(callback.type, "Fn") and T.params(callback.type).size == 1
    return State.fail_help(cx, callback.st, "CHECK-TYPE-MISMATCH", message, span, spawn_argument_help(site.args[0]))
  end

  return State.fail(cx, callback.st, "CHECK-TYPE-MISMATCH", message, span)
end

# The help of a one-parameter function given to Task.spawn alone: a reference gets its argument, a block loses its.
def spawn_argument_help(callback: Ast.Expr) -> String
  case callback
    Ast.Expr.BlockLit(block) ->
      return "a block with a parameter needs an argument: pass it through an Fn variable, or drop the parameter"
    _ -> return "pass its argument: Task.spawn(&f, x)"
  end
end

# What a spawn was given in place of its function, for the message.
def spawn_found(type: T.Type) -> String
  if T.is?(type, "Fn")
    return "a function with #{T.params(type).size} parameter(s)"
  end

  return T.to_text(type)
end

def c_pointer?(type: T.Type) -> Bool
  return T.is?(type, "Opaque") and T.name(type) == "C.Pointer"
end

def handle?(cx: State.Cx, type: T.Type) -> Bool
  return T.is?(type, "Opaque") and (HANDLES.include?(T.name(type)) or cx.resources.include?(T.name(type)))
end

# True for a type Task.spawn_owning can hand over: a handle, a Channel or a C.Pointer, or a struct, enum, List, Map or
# Result whose type holds one somewhere (through fields, variant payloads and type arguments). The walk visits the
# fields of each struct and the payloads of each enum once, so a recursive type ends and a type that names one struct
# many times costs it once; the type arguments of a struct or enum are walked at each use, and a type variable in a
# field or payload holds nothing.
def holds_handle?(cx: State.Cx, type: T.Type) -> Bool
  return holds?(cx, type) do |part: T.Type| handle?(cx, part) or c_pointer?(part) or T.is?(part, "Channel") end
end

# True when the type, or a type inside it (type_parts), passes found.
def holds?(cx: State.Cx, type: T.Type, found: Fn[T.Type, Bool]) -> Bool
  todo = [type]
  seen: Set[String] = Set.new([])
  at = 0
  while at < todo.size
    current = todo[at]
    at += 1
    if found.call(current)
      return true
    end

    todo = todo.concat(type_parts(cx, current, seen))
    if T.is?(current, "Struct") or T.is?(current, "Enum")
      seen = seen.add(T.name(current))
    end
  end

  return false
end

# The types inside a type that holds? walks next: the item of a Result, Optional or List, the key and value of a Map,
# the type arguments of a struct or enum, and the fields or payloads of a struct or enum not seen yet.
def type_parts(cx: State.Cx, type: T.Type, seen: Set[String]) -> List[T.Type]
  case type
    T.Type.Result(item) -> return [item]
    T.Type.Optional(item) -> return [item]
    T.Type.List(item) -> return [item]
    T.Type.Map(key, value) -> return [key, value]
    T.Type.Struct(name, args) ->
      if seen.include?(name) or !cx.structs.has_key?(name)
        return args
      end

      return args.concat(cx.structs[name].map do |field: Model.Named| field.type end)
    T.Type.Enum(name, args) ->
      if seen.include?(name) or !cx.enums.has_key?(name)
        return args
      end

      payloads = cx.enums[name].variants.flat_map do |variant: Model.Variant| variant.payload end
      return args.concat(payloads)
    _ -> return []
  end
end

# Native.close and Native.closed?: one argument, a resource of an extern block. Native.closed? (CLOSED) also takes a
# C.Pointer, since an owned buffer is freed like a resource is closed, and gives a Bool.
def check_native_target(cx: State.Cx, st: State.St, site: State.Site, closed: Bool) -> Result[State.Out]
  target = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  opaque = T.is?(target.type, "Opaque")
  pointer = closed and opaque and T.name(target.type) == "C.Pointer"
  if !pointer and (!opaque or !cx.resources.include?(T.name(target.type)))
    name = "Native.close requires a resource"
    if closed
      name = "Native.closed? requires a resource or a C.Pointer"
    end

    return error(
      State.fail_help(
        cx,
        target.st,
        "CHECK-TYPE-MISMATCH",
        "#{name}, found #{T.to_text(target.type)}",
        Ast.expr_span(site.args[0]),
        "a resource is a type declared with resource Name, free: c_function in an extern block",
      ),
    )
  end

  if closed
    return ok(State.Out(st: target.st, type: T.Type.Bool))
  end

  return ok(State.Out(st: target.st, type: T.Type.Void))
end

# Native.size_of(Type), Native.get_struct(pointer, offset, Type) and Native.put_struct(pointer, offset, value): the
# type, or the type of the value, is a C struct of an extern block, so the VM knows the C type of each field and lays
# the struct out as C does.
def check_native_struct(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  name = site.selected.name
  current = st
  if name != "Native.size_of"
    pointer = try State.expr(cx, current, site.args[0], T.Type.Opaque("C.Pointer"))
    offset = try State.expr(cx, pointer.st, site.args[1], T.Type.Int)
    current = offset.st
  end

  last = site.args[site.args.size - 1]
  if name == "Native.put_struct"
    if type_name?(last)
      return error(
        State.fail_help(
          cx,
          current,
          "CHECK-TYPE-MISMATCH",
          "Native.put_struct writes a value of a struct of an extern block, found a type name",
          Ast.expr_span(last),
          "pass a value of the struct, not its name: Native.put_struct(p, 0, Name(field: value))",
        ),
      )
    end

    value = try State.expr(cx, current, last, T.Type.Unknown)
    if !c_struct?(cx, value.type)
      return error(not_c_struct(cx, value.st, name, T.to_text(value.type), Ast.expr_span(last)))
    end

    return ok(State.Out(st: value.st, type: T.Type.Void))
  end

  case last
    Ast.Expr.TypeName(node) ->
      ref = Ast.TypeRef(id: node.id, name: node.name, args: [], span: node.span)
      type = try CheckTypes.resolve_type(cx, current, ref, false)
      if !c_struct?(cx, type)
        return error(not_c_struct(cx, current, name, T.to_text(type), node.span))
      end

      # The lowering reads the struct from the type name's own type, so an alias gives the struct it names.
      current = State.record_type(current, node.id, type)
      if name == "Native.size_of"
        return ok(State.Out(st: current, type: T.Type.Int))
      end

      return ok(State.Out(st: current, type: type))
    _ -> return error(not_c_struct(cx, current, name, "a value", Ast.expr_span(last)))
  end
end

# Native.callback(Name, &function): Name is a callback of an extern block (CHECK-TYPE-MISMATCH otherwise), and the
# function is a declared function named with & that is not a function of an extern block (CHECK-NATIVE-CALLBACK
# otherwise: an Fn value may capture values, C passing its own context through a user data pointer, and a compute def
# would wait inside the callback). It takes and returns the Agentica types of the callback (CHECK-TYPE-MISMATCH, with
# the C to Agentica help); a generic function takes them from the callback. The call gives the callback, a resource.
def check_native_callback(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  callback_help = "declare the C function type with callback Name(params) -> result in an extern block"
  first = site.args[0]
  wanted = T.Type.Unknown
  current = st
  case first
    Ast.Expr.TypeName(node) ->
      ref = Ast.TypeRef(id: node.id, name: node.name, args: [], span: node.span)
      type = try CheckTypes.resolve_type(cx, current, ref, false)
      if !T.is?(type, "Opaque") or !cx.callbacks.has_key?(T.name(type))
        return error(
          State.fail_help(
            cx,
            current,
            "CHECK-TYPE-MISMATCH",
            "Native.callback requires a callback of an extern block, found #{T.to_text(type)}",
            node.span,
            callback_help,
          ),
        )
      end

      # The lowering reads the signature from the type name's own type, so an alias gives the callback it names.
      current = State.record_type(current, node.id, type)
      wanted = type
    _ ->
      return error(
        State.fail_help(
          cx,
          current,
          "CHECK-TYPE-MISMATCH",
          "Native.callback requires a callback of an extern block, found a value",
          Ast.expr_span(first),
          callback_help,
        ),
      )
  end

  target = site.args[1]
  expected = cx.callbacks[T.name(wanted)]
  named = callback_target(target)
  if named == "" or cx.natives.include?(named)
    return error(
      State.fail_help(
        cx,
        current,
        "CHECK-NATIVE-CALLBACK",
        "Native.callback takes &name of a declared function that is not a function of an extern block",
        Ast.expr_span(target),
        "write a def that takes #{T.to_text(expected)} and pass &name; C's user data pointer carries any context",
      ),
    )
  end

  # A plain function is checked against its own type, so a mismatch gets the help below; a generic one takes its
  # type parameters from the callback.
  context = T.Type.Unknown
  found = cx.functions.get(named)
  if found.some? and found.unwrap!.type_parameters.size > 0
    context = expected
  end

  given = try State.expr(cx, current, target, context)
  if !T.same?(given.type, expected)
    return error(
      State.fail_help(
        cx,
        given.st,
        "CHECK-TYPE-MISMATCH",
        "the callback #{T.to_text(wanted)} calls #{T.to_text(expected)}, found #{T.to_text(given.type)}",
        Ast.expr_span(target),
        "a C integer type is Int, C.Double and C.Float are Float, C.Bool is Bool, C.String is String",
      ),
    )
  end

  return ok(State.Out(st: given.st, type: wanted))
end

# The function that the second argument of Native.callback names with &, or "" for any other value.
def callback_target(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.FunctionRef(node) -> return node.name
    _ -> return ""
  end
end

def type_name?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.TypeName(node) -> return true
    _ -> return false
  end
end

def c_struct?(cx: State.Cx, type: T.Type) -> Bool
  return T.is?(type, "Struct") and cx.c_structs.include?(T.name(type))
end

# CHECK-TYPE-MISMATCH of a struct builtin of Native given something that is not a C struct of an extern block.
def not_c_struct(cx: State.Cx, st: State.St, name: String, found: String, span: Source.Span) -> String
  return State.fail_help(
    cx,
    st,
    "CHECK-TYPE-MISMATCH",
    "#{name} requires a struct of an extern block, found #{found}",
    span,
    "declare the C struct with struct Name ... end in an extern block, its fields in the order of the C header",
  )
end

def check_await(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try State.expr(cx, st, site.args[0], T.task_of(site.expected))
  if !T.is?(target.type, "Task")
    return error(
      State.fail(cx, target.st, "CHECK-TYPE-MISMATCH", "Task.await requires a task", Ast.expr_span(site.args[0])),
    )
  end

  return ok(State.Out(st: target.st, type: T.item(target.type)))
end

# Task.await with a timeout gives Await[R]: Await.Done(value) or Await.TimedOut.
def check_await_timeout(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  context = T.Type.Unknown
  if T.is?(site.expected, "Enum") and T.name(site.expected) == "Await"
    context = T.Type.Task(T.args(site.expected)[0])
  end

  target = try State.expr(cx, st, site.args[0], context)
  if !T.is?(target.type, "Task")
    return error(
      State.fail(cx, target.st, "CHECK-TYPE-MISMATCH", "Task.await requires a task", Ast.expr_span(site.args[0])),
    )
  end

  timeout = try State.expr(cx, target.st, site.args[1], T.Type.Int)
  return ok(State.Out(st: timeout.st, type: T.Type.Enum("Await", [T.item(target.type)])))
end

# Task.map(items, limit, timeout_ms, f): the callback is a block (which gets the item type from the list) or a function
# value of one parameter, and gives a Result; the call gives one Result per item. A block whose Result type the
# expected type does not give takes it from its body (Slot.InferResult), so try works in it.
def check_task_map(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  callback = site.args[3]
  case callback
    Ast.Expr.BlockLit(block) -> return task_map_block(cx, st, site, block)
    _ -> return task_map_function(cx, st, site, callback)
  end
end

def task_map_block(cx: State.Cx, st: State.St, site: State.Site, block: Ast.BlockLit) -> Result[State.Out]
  annotated = try Lists.annotated_parameter(cx, st, block, 0)
  items = try Args.list_argument(cx, st, site, T.list_of(annotated))
  counts = try task_map_counts(cx, items.st, site)
  checked = try Stmt.check_block_body(
    cx,
    counts.st,
    block,
    some([T.item(items.type)]),
    task_map_block_result(site.expected),
    none,
  )
  return task_map_result(cx, checked.st, checked.type, block.span)
end

def task_map_function(cx: State.Cx, st: State.St, site: State.Site, callback: Ast.Expr) -> Result[State.Out]
  checked = try State.expr(cx, st, callback, T.Type.Unknown)
  span = Ast.expr_span(callback)
  if !T.is?(checked.type, "Fn") or T.params(checked.type).size != 1
    return error(
      State.fail(cx, checked.st, "CHECK-TYPE-MISMATCH", "Task.map requires a function with one parameter", span),
    )
  end

  items = try Args.list_argument(cx, checked.st, site, T.Type.List(T.params(checked.type)[0]))
  counts = try task_map_counts(cx, items.st, site)
  return task_map_result(cx, counts.st, checked.type, span)
end

# limit and timeout_ms are Ints; their values are checked when the call runs.
def task_map_counts(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  limit = try State.expr(cx, st, site.args[1], T.Type.Int)
  return State.expr(cx, limit.st, site.args[2], T.Type.Int)
end

# The Result type the block must give: the item of the expected list when that is a Result, else Result[Unknown], which
# says the body decides the inner type.
def task_map_block_result(expected: T.Type) -> T.Type
  if T.is?(expected, "List") and T.is?(T.item(expected), "Result")
    return T.item(expected)
  end

  return T.Type.Result(T.Type.Unknown)
end

# The call gives a list of the callback's Results; a callback that gives anything else is CHECK-TYPE-MISMATCH.
def task_map_result(cx: State.Cx, st: State.St, callback: T.Type, span: Source.Span) -> Result[State.Out]
  result = T.result(callback)
  if !T.is?(result, "Result")
    return error(State.mismatch(cx, st, T.Type.Result(T.Type.Var("T")), result, span))
  end

  return ok(State.Out(st: st, type: T.Type.List(result)))
end

# ATS.new needs the table type from its context. The resolved type has passed the value rule already; the check here
# keeps it for a type that reaches the call some other way.
def check_ats_new(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  span = site.node.span
  if T.unknown?(site.expected)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-EXPECTED-TYPE",
        "a table needs an expected type",
        span,
        "annotate the variable, for example hits: ATS[String, Int] = ATS.new()",
      ),
    )
  end

  if !T.is?(site.expected, "ATS")
    return error(State.mismatch(cx, st, site.expected, T.Type.ATS(T.Type.Var("K"), T.Type.Var("V")), span))
  end

  if !CheckTypes.ats_value?(cx, T.value(site.expected))
    return error(CheckTypes.ats_value_failure(cx, st, T.value(site.expected), span))
  end

  return ok(State.Out(st: st, type: site.expected))
end

# An ATS builtin other than ATS.new: argument 0 is an ATS[K, V], the K and V of the row become the table's key and
# value types, the other arguments are checked against the row's parameters, and the call has the row's result. A row
# whose table parameter fixes V (ATS.add takes ATS[K, Int]) refuses a table of another value type.
def check_ats_call(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.ats_argument(cx, st, site)
  found: Map[String, T.Type] = {"K": T.key(target.type), "V": T.value(target.type)}
  parameters = site.selected.parameters
  table = CheckTypes.substitute(parameters[0].type, found)
  if !T.same?(table, target.type)
    return error(State.mismatch(cx, target.st, table, target.type, Ast.expr_span(site.args[0])))
  end

  current = target.st
  index = 1
  while index < site.args.size
    out = try State.expr(cx, current, site.args[index], CheckTypes.substitute(parameters[index].type, found))
    current = out.st
    index += 1
  end

  return ok(State.Out(st: current, type: CheckTypes.substitute(site.selected.result, found)))
end

# Channel.new needs the channel type from its context.
def check_channel_new(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  capacity = try State.expr(cx, st, site.args[0], T.Type.Int)
  span = site.node.span
  if T.unknown?(site.expected)
    return error(
      State.fail_help(
        cx,
        capacity.st,
        "CHECK-EXPECTED-TYPE",
        "a channel needs an expected type",
        span,
        "annotate the variable, for example ch: Channel[Int] = Channel.new(8)",
      ),
    )
  end

  if !T.is?(site.expected, "Channel")
    return error(State.mismatch(cx, capacity.st, site.expected, T.Type.Channel(T.Type.Var("T")), span))
  end

  return ok(State.Out(st: capacity.st, type: site.expected))
end

def check_channel_send(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.channel_argument(cx, st, site)
  value = try State.expr(cx, target.st, site.args[1], T.item(target.type))
  timeout = try State.expr(cx, value.st, site.args[2], T.Type.Int)
  return ok(State.Out(st: timeout.st, type: T.Type.Result(T.Type.Void)))
end

def check_channel_recv(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.channel_argument(cx, st, site)
  timeout = try State.expr(cx, target.st, site.args[1], T.Type.Int)
  return ok(State.Out(st: timeout.st, type: T.Type.Result(T.item(target.type))))
end

# A builtin whose one argument is a target of a shape (a Task[R] or a Channel[T] of any item type), checked by
# `argument`; the call has the type of its row (Task.cancel, Channel.close, Channel.closed?).
def check_target(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  argument: Fn[State.Cx, State.St, State.Site, Result[State.Out]],
) -> Result[State.Out]
  target = try argument.call(cx, st, site)
  return ok(State.Out(st: target.st, type: site.selected.result))
end

# Profile.measure(label) do ... end, Native.memory_pointer(size) do |buf| ... end and Native.from_string(text) do |buf|
# ... end: the first argument has the type `first`, then a block or a function that takes `params`; the call has the
# type the block returns. The context of the call is the block's expected result.
def check_block_value(
  cx: State.Cx,
  st: State.St,
  site: State.Site,
  first: T.Type,
  params: List[T.Type],
) -> Result[State.Out]
  leading = try State.expr(cx, st, site.args[0], first)
  wanted = site.expected
  callback = site.args[1]
  case callback
    Ast.Expr.BlockLit(block) ->
      known = some(params)
      checked = try Stmt.check_block_body(cx, leading.st, block, known, wanted, none)
      return ok(State.Out(st: checked.st, type: T.result(checked.type)))
    _ ->
      checked = try State.expr(cx, leading.st, callback, T.Type.Unknown)
      if !T.is?(checked.type, "Fn") or !T.same_all?(T.params(checked.type), params)
        return error(
          State.fail(
            cx,
            checked.st,
            "CHECK-TYPE-MISMATCH",
            "#{site.selected.name} requires a block or a function #{block_parameters(params)}",
            Ast.expr_span(callback),
          ),
        )
      end

      return ok(State.Out(st: checked.st, type: T.result(checked.type)))
  end
end

# How the help of check_block_value names the parameters of the block: "with no parameters", "that takes C.Pointer".
def block_parameters(params: List[T.Type]) -> String
  if params.size == 0
    return "with no parameters"
  end

  return "that takes #{params.map do |param: T.Type| T.to_text(param) end.join(", ")}"
end

def check_map_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.MapHas -> return check_map_has(cx, st, site)
    Model.Rule.MapKeys ->
      target = try Args.map_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.List(T.key(target.type))))
    Model.Rule.MapValues ->
      target = try Args.map_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.List(T.value(target.type))))
    Model.Rule.MapGet -> return check_map_get(cx, st, site, false)
    Model.Rule.MapGetDefault -> return check_map_get(cx, st, site, true)
    Model.Rule.MapDelete -> return check_map_delete(cx, st, site)
    Model.Rule.MapSize ->
      target = try Args.map_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.Int))
    Model.Rule.MapPut -> return check_map_put(cx, st, site)
    _ -> return check_set_rule(cx, st, site, rule)
  end
end

def check_map_has(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.map_argument(cx, st, site, T.Type.Unknown)
  key = try State.expr(cx, target.st, site.args[1], T.key(target.type))
  return ok(State.Out(st: key.st, type: T.Type.Bool))
end

# Map.get gives a Result; with a default it gives the value. The value type of the map may come from the expected type,
# or from the default when the map is the literal {}.
def check_map_get(cx: State.Cx, st: State.St, site: State.Site, with_default: Bool) -> Result[State.Out]
  value_context = T.only_optional_item(site.expected)
  if with_default
    value_context = site.expected
  end

  current = st
  if T.unknown?(value_context) and with_default and Args.empty_map?(site.args[0])
    default = try State.expr(cx, current, site.args[2], T.Type.Unknown)
    current = default.st
    value_context = default.type
  end

  context = T.Type.Unknown
  if !T.unknown?(value_context)
    key = try State.expr(cx, current, site.args[1], T.Type.Unknown)
    current = key.st
    context = T.Type.Map(key.type, value_context)
  end

  target = try Args.map_argument(cx, current, site, context)
  key = try State.expr(cx, target.st, site.args[1], T.key(target.type))
  current = key.st
  if with_default
    default = try State.expr(cx, current, site.args[2], T.value(target.type))
    return ok(State.Out(st: default.st, type: T.value(target.type)))
  end

  return ok(State.Out(st: current, type: T.Type.Optional(T.value(target.type))))
end

def check_map_delete(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.map_argument(cx, st, site, T.only_map(site.expected))
  key = try State.expr(cx, target.st, site.args[1], T.key(target.type))
  return ok(State.Out(st: key.st, type: target.type))
end

def check_map_put(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.map_argument(cx, st, site, T.Type.Unknown)
  key = try State.expr(cx, target.st, site.args[1], T.key(target.type))
  value = try State.expr(cx, key.st, site.args[2], T.value(target.type))
  return ok(State.Out(st: value.st, type: target.type))
end

def check_set_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.SetNew -> return check_set_new(cx, st, site)
    Model.Rule.SetAdd -> return check_set_add(cx, st, site)
    Model.Rule.SetInclude ->
      target = try Args.set_argument(cx, st, site, T.Type.Unknown)
      element = try State.expr(cx, target.st, site.args[1], T.item(target.type))
      return ok(State.Out(st: element.st, type: T.Type.Bool))
    Model.Rule.SetQuery ->
      target = try Args.set_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: site.selected.result))
    Model.Rule.SetToA ->
      target = try Args.set_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.List(T.item(target.type))))
    Model.Rule.SetCombine -> return check_set_combine(cx, st, site, false)
    Model.Rule.SetSubset -> return check_set_combine(cx, st, site, true)
    _ -> return error(State.fail(cx, st, "CHECK-INTERNAL", "unsupported builtin rule", site.node.span))
  end
end

# Set.new: a list of Int or String; an empty list needs the set type from its context.
def check_set_new(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  items = site.args[0]
  context = T.Type.Unknown
  if T.is?(site.expected, "Set")
    context = T.Type.List(T.item(site.expected))
  end

  span = site.node.span
  if Args.empty_list?(items) and T.unknown?(context)
    if !T.unknown?(site.expected)
      return error(State.mismatch(cx, st, site.expected, T.Type.Set(T.Type.Var("T")), span))
    end

    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-EMPTY-SET-TYPE",
        "an empty set needs an expected type, for example \"Set[Int]\"",
        span,
        (
          "annotate the variable: seen: Set[Int] = Set.new([]); " +
          "a parameter, a field or a function result also gives the type"
        ),
      ),
    )
  end

  list = try Args.list_argument(cx, st, site, context)
  element = T.item(list.type)
  if !CheckTypes.key_here?(cx, element)
    return error(
      State.fail(
        cx,
        list.st,
        "CHECK-SET-ELEMENT-TYPE",
        "a Set element must be Int, String or Bytes, found #{T.to_text(element)}",
        Ast.expr_span(items),
      ),
    )
  end

  return ok(State.Out(st: list.st, type: T.Type.Set(element)))
end

# Set.add and Set.delete: the element has the element type.
def check_set_add(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.set_argument(cx, st, site, T.only_set(site.expected))
  element = try State.expr(cx, target.st, site.args[1], T.item(target.type))
  return ok(State.Out(st: element.st, type: target.type))
end

# Set.union, intersection, difference (a set) and subset? (a Bool): the second set has the type of the first.
def check_set_combine(cx: State.Cx, st: State.St, site: State.Site, subset: Bool) -> Result[State.Out]
  context = T.Type.Unknown
  if !subset
    context = T.only_set(site.expected)
  end

  target = try Args.set_argument(cx, st, site, context)
  other = try State.expr(cx, target.st, site.args[1], target.type)
  if subset
    return ok(State.Out(st: other.st, type: T.Type.Bool))
  end

  return ok(State.Out(st: other.st, type: target.type))
end
