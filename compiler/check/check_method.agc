## Methods and fields. A method call or a field
## access that is not a struct field names a builtin of the receiver's kind; it is checked as the call of that builtin
## with the receiver as first argument, and the resolution is recorded by node id for lowering.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import Calls from "check_call"
import Help from "check_help"
import Names from "check_names"
import State from "check_state"
import CheckTypes from "check_types"

## Checks target.name(args).
export def check_method(cx: State.Cx, st: State.St, node: Ast.MethodCall, expected: T.Type) -> Result[State.Out]
  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if node.name == "each" and foreach_call?(node.target)
    return error(
      State.fail_help(
        cx,
        target.st,
        "CHECK-LAZY-NO-STEP",
        "File.foreach(...).each with no step in between is File.each_line",
        node.span,
        "use File.each_line(path, buffer_bytes, timeout_ms) do |line| ... end; keep File.foreach for a chain " +
        "with a step, such as .filter do |line| ... end before .each",
      ),
    )
  end

  return method_on(cx, target, node.id, node.target, node.name, node.args, node.span, expected)
end

## Checks target.name: a struct field, or a method without arguments (to_s, size, ...).
export def check_field_access(cx: State.Cx, st: State.St, node: Ast.FieldAccess, expected: T.Type) -> Result[State.Out]
  case node.target
    Ast.Expr.TypeName(type_name) ->
      if node.name == "members"
        return check_members(cx, st, node, type_name)
      end

    _ -> st = st
  end

  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if field_target?(cx, target.type, node.name)
    return check_struct_field(cx, target.st, node, target.type)
  end

  return method_on(cx, target, node.id, node.target, node.name, [], node.span, expected)
end

# Type.members: the fields of a struct type, in declaration order, as a List[StructMember]. Lowering builds the list
# from the fields recorded here, so the program needs no runtime support. An alias is refused as a struct
# construction is (CHECK-UNKNOWN-TYPE); an enum or a resource has no members (CHECK-UNKNOWN-METHOD).
def check_members(cx: State.Cx, st: State.St, node: Ast.FieldAccess, type_name: Ast.TypeName) -> Result[State.Out]
  name = type_name.name
  display = T.display_name(name)
  fields = cx.structs.get(name)
  if fields.ok? and !cx.aliases.has_key?(name)
    resolved = State.record_resolved(st, node.id, State.Resolved.Members(fields.unwrap!))
    return ok(State.Out(st: resolved, type: T.Type.List(T.Type.Struct("StructMember", []))))
  end

  if cx.aliases.has_key?(name)
    target = try CheckTypes.alias_target_text(cx, st, name)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNKNOWN-TYPE",
        "a type alias is not a declared struct",
        node.span,
        "#{display} names #{target}; use members on the underlying struct instead",
      ),
    )
  end

  return error(
    State.fail_help(
      cx,
      st,
      "CHECK-UNKNOWN-METHOD",
      "#{display} has no method \"members\"",
      node.span,
      "members lists the fields of a struct type; #{display} is not a struct",
    ),
  )
end

# A struct is read by field unless the name is to_s or inspect and the struct has no such field.
def field_target?(cx: State.Cx, target: T.Type, name: String) -> Bool
  if !T.is?(target, "Struct")
    return false
  end

  if name == "to_s" or name == "inspect"
    return Calls.find_field(cx.structs[T.name(target)], name).ok?
  end

  return true
end

# The type of the field, CHECK-UNKNOWN-FIELD when the struct has none of that name.
def check_struct_field(cx: State.Cx, st: State.St, node: Ast.FieldAccess, target: T.Type) -> Result[State.Out]
  fields = CheckTypes.fields_of(cx, target)
  field = Calls.find_field(fields, node.name)
  if !field.ok?
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNKNOWN-FIELD",
        "\"#{T.display_name(T.name(target))}\" has no field \"#{node.name}\"",
        node.span,
        Help.field_help(node.name, fields),
      ),
    )
  end

  return ok(State.Out(st: st, type: field.unwrap!.type))
end

# What the method is: "self", "text" (to_s) or "inspect" for a data value, the full name of a builtin, or "" when there
# is none.
def method_kind(cx: State.Cx, target: T.Type, kind: String, name: String) -> String
  if kind != ""
    found = Names.resolve_method(cx, kind, name)
    if found != ""
      return found
    end
  end

  if name == "to_s" and CheckTypes.data?(cx, target)
    return "text"
  elsif name == "inspect" and CheckTypes.data?(cx, target)
    return "inspect"
  end

  return ""
end

# The method on a receiver that is already checked. The resolution is recorded by the id of the node.
def method_on(
  cx: State.Cx,
  target: State.Out,
  id: Int,
  target_node: Ast.Expr,
  name: String,
  args: List[Ast.Expr],
  span: Source.Span,
  expected: T.Type,
) -> Result[State.Out]
  type = target.type
  kind = Names.receiver_kind(type)
  resolved = method_kind(cx, type, kind, name)
  if resolved == ""
    return error(
      State.fail_maybe(
        cx,
        target.st,
        "CHECK-UNKNOWN-METHOD",
        "#{T.to_text(type)} has no method \"#{name}\"",
        span,
        unknown_method_help(cx, target.st, id, type, kind, name),
      ),
    )
  end

  if resolved == "self" or resolved == "text" or resolved == "inspect"
    return check_own_method(cx, target.st, id, resolved, type, name, args, span, expected)
  end

  typed = Ast.Expr.Typed(
    Ast.TypedTarget(id: Ast.expr_id(target_node), target: target_node, type: type, span: Ast.expr_span(target_node)),
  )
  call = Ast.Call(id: id, name: resolved, args: [typed].concat(args), piped: false, parenthesized: true, span: span)
  st = State.record_resolved(target.st, id, State.Resolved.Call(resolved, type))
  return Calls.check_call(cx, st, call, expected)
end

# to_s and inspect, and a to_s that is the receiver itself: they take no arguments and give a String (or the receiver).
def check_own_method(
  cx: State.Cx,
  st: State.St,
  id: Int,
  resolved: String,
  type: T.Type,
  name: String,
  args: List[Ast.Expr],
  span: Source.Span,
  expected: T.Type,
) -> Result[State.Out]
  if args.size > 0
    return error(State.fail(cx, st, "CHECK-ARITY", "\"#{name}\" takes no arguments", span))
  end

  result = T.Type.String
  how = State.Resolved.Text(type)
  if resolved == "self"
    result = type
    how = State.Resolved.Self(type)
  elsif resolved == "inspect"
    how = State.Resolved.Inspect(type)
  end

  checked = try State.ensure(cx, st, result, expected, span)
  return ok(State.Out(st: State.record_resolved(st, id, how), type: checked))
end

# The help of CHECK-UNKNOWN-METHOD: a range that needs parentheses, then what is special about the receiver.
def unknown_method_help(cx: State.Cx, st: State.St, id: Int, target: T.Type, kind: String, name: String) -> String
  if st.range_chain.any? do |link: Int| link == id end and Names.resolve_method(cx, "Range", name) != ""
    return "a method call on a range needs parentheses: (a..b).#{name}"
  elsif name == "to_s" or name == "inspect"
    return (
      "only data values have to_s and inspect: numbers, Bool, String, nil, Json, ranges, and lists, maps, sets, " +
      "Results, structs and enums of those"
    )
  elsif T.is?(target, "Struct")
    return struct_help(cx, target, name)
  elsif name == "with"
    return "with copies a struct with some fields changed; the value before .with must be a struct"
  elsif kind != ""
    return kind_help(cx, target, kind, name)
  elsif CheckTypes.data?(cx, target)
    return Help.near(name, ["to_s", "inspect"], [])
  end

  return ""
end

# A struct has no methods: the help says what the name could be instead.
def struct_help(cx: State.Cx, target: T.Type, name: String) -> String
  fields = CheckTypes.fields_of(cx, target)
  field = Calls.find_field(fields, name)
  if cx.functions.has_key?(name)
    return "structs have no methods; call #{name}(...) with the struct as an argument"
  elsif field.ok? and T.is?(field.unwrap!.type, "Fn")
    return "#{name} is a function field; call it with .#{name}.call(...)"
  elsif name == "with"
    # No did-you-mean here: a field close to "with" is not a typo of it.
    return "with needs the fields to change, as in .with(field: value); #{Help.field_list(fields)}"
  end

  return "structs have no methods; #{Help.field_help(name, fields)}"
end

# The help for a method another language has, a close name, or the methods the kind has.
def kind_help(cx: State.Cx, target: T.Type, kind: String, name: String) -> String
  foreign = Names.foreign_method_help(cx, kind, name)
  if foreign != ""
    return foreign
  end

  names = method_names(cx, target, kind)
  guess = Help.near(name, names, [])
  if guess != ""
    return guess
  end

  return "#{T.to_text(target)} methods: #{names.sort.join(", ")}"
end

# The methods of the kind, with to_s and inspect for a data value.
def method_names(cx: State.Cx, target: T.Type, kind: String) -> List[String]
  names = Names.method_names(cx, kind)
  if CheckTypes.data?(cx, target)
    names = names.concat(
      ["to_s", "inspect"].filter do |own: String| !names.any? do |known: String| known == own end end,
    )
  end

  return names
end

# True for a File.foreach call written directly as the receiver: .each on it is the one job of File.each_line
# (docs/future/27-iteration-and-concurrency.md 27.4, one way per job). A Lazy held in a variable is not followed.
def foreach_call?(target: Ast.Expr) -> Bool
  case target
    Ast.Expr.Call(call) -> return call.name == "File.foreach"
    _ -> return false
  end
end
