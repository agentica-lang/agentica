## The checking rules of the Map, Set, Task and Channel builtins (src/checker.rkt, check-builtin-call: task-spawn ... set-subset). A rule takes the call (State.Site) and returns the new state with the type of the call.

import Ast from "ast"
import Model from "builtin_model"
import Args from "check_args"
import State from "check_state"
import CheckTypes from "check_types"
import T from "types"

## Checks a call of a Task, Channel, Map or Set builtin by its rule. Any other rule is the caller's.
export def check_collection_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.TaskSpawn -> return check_spawn(cx, st, site, false)
    Model.Rule.TaskSpawnOwning -> return check_spawn(cx, st, site, true)
    Model.Rule.TaskAwait -> return check_await(cx, st, site)
    Model.Rule.TaskAwaitTimeout -> return check_await_timeout(cx, st, site)
    Model.Rule.ChannelNew -> return check_channel_new(cx, st, site)
    Model.Rule.ChannelSend -> return check_channel_send(cx, st, site)
    Model.Rule.ChannelRecv -> return check_channel_recv(cx, st, site)
    Model.Rule.ChannelTarget -> return check_channel_target(cx, st, site)
    _ -> return check_map_rule(cx, st, site, rule)
  end
end

# Task.spawn and Task.spawn_owning: a function of one parameter and the argument it gets. The owning form also hands over a handle or channel.
def check_spawn(cx: State.Cx, st: State.St, site: State.Site, owning: Bool) -> Result[State.Out]
  callback = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  if !T.is(callback.type, "Fn") or T.params(callback.type).size != 1
    return error(State.fail(cx, callback.st, "CHECK-TYPE-MISMATCH", site.selected.name + " requires a function with one parameter", Ast.expr_span(site.args[0])))
  end
  handed = try State.expr(cx, callback.st, site.args[1], T.params(callback.type)[0])
  if owning and !handle?(cx, handed.type) and !T.is(handed.type, "Channel")
    return error(State.fail_help(cx, handed.st, "CHECK-NOT-A-HANDLE", "Task.spawn_owning gives a handle to the new task, but the argument is " + T.to_text(handed.type), Ast.expr_span(site.args[1]), "pass a FileHandle, Socket, Listener, Process, HttpServer or Channel; Task.spawn passes any other value"))
  end
  return ok(State.Out(st: handed.st, type: T.Type.Task(T.result(callback.type))))
end

def handle?(cx: State.Cx, type: T.Type) -> Bool
  return T.is(type, "Opaque") and cx.catalog.handles.include?(T.name(type))
end

def check_await(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try State.expr(cx, st, site.args[0], T.task_of(site.expected))
  if !T.is(target.type, "Task")
    return error(State.fail(cx, target.st, "CHECK-TYPE-MISMATCH", "Task.await requires a task", Ast.expr_span(site.args[0])))
  end
  return ok(State.Out(st: target.st, type: T.item(target.type)))
end

# Task.await with a timeout gives Await[R]: Await.Done(value) or Await.TimedOut.
def check_await_timeout(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  context = T.Type.Unknown
  if T.is(site.expected, "Enum") and T.name(site.expected) == "Await"
    context = T.Type.Task(T.args(site.expected)[0])
  end
  target = try State.expr(cx, st, site.args[0], context)
  if !T.is(target.type, "Task")
    return error(State.fail(cx, target.st, "CHECK-TYPE-MISMATCH", "Task.await requires a task", Ast.expr_span(site.args[0])))
  end
  timeout = try State.expr(cx, target.st, site.args[1], T.Type.Int)
  return ok(State.Out(st: timeout.st, type: T.Type.Enum("Await", [T.item(target.type)])))
end

# Channel.new needs the channel type from its context.
def check_channel_new(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  capacity = try State.expr(cx, st, site.args[0], T.Type.Int)
  span = site.node.span
  if T.unknown?(site.expected)
    return error(State.fail_help(cx, capacity.st, "CHECK-EXPECTED-TYPE", "a channel needs an expected type", span, "annotate the variable, for example ch: Channel[Int] = Channel.new(8)"))
  end
  if !T.is(site.expected, "Channel")
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

def check_channel_target(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  target = try Args.channel_argument(cx, st, site)
  return ok(State.Out(st: target.st, type: site.selected.result))
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

# Map.get gives a Result; with a default it gives the value. The value type of the map may come from the expected type, or from the default when the map is the literal {}.
def check_map_get(cx: State.Cx, st: State.St, site: State.Site, with_default: Bool) -> Result[State.Out]
  value_context = T.only_result_item(site.expected)
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
  return ok(State.Out(st: current, type: T.Type.Result(T.value(target.type))))
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
  if T.is(site.expected, "Set")
    context = T.Type.List(T.item(site.expected))
  end
  span = site.node.span
  if Args.empty_list?(items) and T.unknown?(context)
    if !T.unknown?(site.expected)
      return error(State.mismatch(cx, st, site.expected, T.Type.Set(T.Type.Var("T")), span))
    end
    return error(State.fail_help(cx, st, "CHECK-EMPTY-SET-TYPE", "an empty set needs an expected type, for example \"Set[Int]\"", span, "annotate the variable: seen: Set[Int] = Set.new([]); a parameter, a field or a function result also gives the type"))
  end
  list = try Args.list_argument(cx, st, site, context)
  element = T.item(list.type)
  if !CheckTypes.key_type?(element)
    return error(State.fail(cx, list.st, "CHECK-SET-ELEMENT-TYPE", "a Set element must be Int or String, found " + T.to_text(element), Ast.expr_span(items)))
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
