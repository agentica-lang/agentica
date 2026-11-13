## Methods and fields. A method call or a field
## access that is not a struct field names a builtin of the receiver's kind; it is checked as the call of that builtin
## with the receiver as first argument, and the resolution is recorded by node id for lowering.

import Model from "../catalog/builtin_model"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import Calls from "check_call"
import Help from "check_help"
import Names from "check_names"
import State from "check_state"
import Rules from "check_rules"
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

  # A pipe step resolves only to methods: `h |> run(4)` on an Fn field `run` would drop `h`.
  piped = Calls.piped_method?(node)
  field = fn_field(cx, target.type, node.name)
  if field.some? and piped
    return error(unknown_piped(cx, target.st, target.type, node.target, node.name, node.span, ""))
  elsif field.some? and State.private_fields(cx, T.name(target.type)).include?(node.name)
    return error(State.private_field(cx, target.st, T.name(target.type), node.name, node.name_span))
  elsif field.some?
    return check_field_call(cx, target.st, node, field.unwrap!)
  end

  method_on(cx, target, node.id, node.target, node.name, node.args, node.named, node.span, piped, expected)
end

## The call of a function value of the given type: one argument for each parameter, each checked against its type, and
## the result type of the function. Shared by `f.call(args)` and a call of an Fn field (`s.name(args)`).
export def apply_function(
  cx: State.Cx,
  st: State.St,
  type: T.Type,
  args: List[Ast.Expr],
  span: Source.Span,
) -> Result[State.Out]
  params = T.params(type)
  if params.size != args.size
    return error(State.fail(cx, st, "CHECK-ARITY", "wrong number of function arguments", span))
  end

  current = st
  index = 0
  while index < params.size
    out = try State.expr(cx, current, args[index], params[index])
    current = out.st
    index += 1
  end

  ok(State.Out(st: current, type: T.result(type)))
end

## Checks target.name: a struct field, or a method without arguments (to_s, size, ...).
export def check_field_access(cx: State.Cx, st: State.St, node: Ast.FieldAccess, expected: T.Type) -> Result[State.Out]
  case node.target
    Ast.Expr.TypeName(type_name) ->
      if node.name == "members"
        return check_members(cx, st, node, type_name)
      elsif node.name == "codec"
        return check_codec(cx, st, node, type_name)
      end

    _ -> st = st
  end

  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  return check_struct_field(cx, target.st, node, target.type) if field_target?(cx, target.type, node.name)

  method_on(cx, target, node.id, node.target, node.name, [], [], node.span, false, expected)
end

# The Fn field a struct has under the name, if any. Such a field wins over a method of the same name (to_s, inspect):
# `s.name(args)` calls the function the field holds, as `s.name.call(args)` does. A field of another type is not
# callable (CHECK-UNKNOWN-METHOD). A field named `with` cannot hold a function (check_register), so `with(` stays the
# struct update.
def fn_field(cx: State.Cx, target: T.Type, name: String) -> Optional[Model.Named]
  return none if !T.is?(target, "Struct")

  found = Calls.find_field(CheckTypes.fields_of(cx, target), name)
  return some(found.unwrap!) if found.ok? and T.is?(found.unwrap!.type, "Fn")

  none
end

# target.name(args) where name is an Fn field: the arguments match the parameters of the function the field holds.
def check_field_call(cx: State.Cx, st: State.St, node: Ast.MethodCall, field: Model.Named) -> Result[State.Out]
  if node.named.size > 0
    arg = node.named[0]
    message = "the field \"#{node.name}\" holds a function value, which has no parameter names"
    help = "a function value takes positional arguments: #{node.name}(...) without names"
    return error(State.fail_help(cx, st, "CHECK-UNKNOWN-ARGUMENT", message, arg.span, help))
  end

  called = try apply_function(cx, st, field.type, node.args, node.span)
  ok(State.Out(st: State.record_resolved(called.st, node.id, State.Resolved.FieldCall), type: called.type))
end

# Type.members: the fields of a struct type, in declaration order, as a List[StructMember]. Lowering builds the list
# from the fields recorded here, so the program needs no runtime support. An alias is refused as a struct
# construction is (CHECK-UNKNOWN-TYPE); an enum or a resource has no members (CHECK-UNKNOWN-METHOD). Outside the module
# of a struct with private fields it is CHECK-PRIVATE-FIELD, as Type.codec is.
def check_members(cx: State.Cx, st: State.St, node: Ast.FieldAccess, type_name: Ast.TypeName) -> Result[State.Out]
  if type_name.args.size > 0
    return error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", "members requires a struct name", type_name.span))
  end

  name = type_name.name
  display = T.display_name(name)
  fields = cx.structs.get(name)
  hidden = State.private_fields(cx, name)
  if fields.some? and !cx.aliases.has_key?(name) and hidden.size > 0
    return error(State.private_field(cx, st, name, hidden[0], type_name.span))
  elsif fields.some? and !cx.aliases.has_key?(name)
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

  error(
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

# Type.codec: the codec of a struct or enum JSON.decode takes, a Codec[T]. Lowering builds the codec from the name and
# the fields recorded here (none for an enum): the members of the codec are the ones Type.members gives. A type that
# cannot be decoded is CHECK-NOT-DECODABLE, as for JSON.decode. A codec reads and writes every field, so a type that
# holds a struct with private fields is CHECK-PRIVATE-FIELD outside that struct's module.
def check_codec(cx: State.Cx, st: State.St, node: Ast.FieldAccess, type_name: Ast.TypeName) -> Result[State.Out]
  type = try Rules.check_codec_of(cx, st, type_name)
  name = T.name(T.item(type))
  fields = cx.structs.get(name)
  members: List[Model.Named] = []
  if fields.some?
    members = fields.unwrap!
  end

  resolved = State.record_resolved(st, node.id, State.Resolved.Codec(name, members))
  ok(State.Out(st: resolved, type: type))
end

# A struct is read by field unless the name is to_s or inspect and the struct has no such field.
def field_target?(cx: State.Cx, target: T.Type, name: String) -> Bool
  return false if !T.is?(target, "Struct")

  if name == "to_s" or name == "inspect"
    # A private field named to_s or inspect is not seen outside its module, so the name is the method there.
    owner = T.name(target)
    return Calls.find_field(cx.structs[owner], name).ok? and !State.private_fields(cx, owner).include?(name)
  end

  true
end

# The type of the field, CHECK-UNKNOWN-FIELD when the struct has none of that name.
def check_struct_field(cx: State.Cx, st: State.St, node: Ast.FieldAccess, target: T.Type) -> Result[State.Out]
  fields = CheckTypes.fields_of(cx, target)
  field = Calls.find_field(fields, node.name)
  if !field.ok?
    help = Help.field_help(node.name, State.shown_fields(cx, T.name(target), fields))
    if T.error?(target) and Names.resolve_method(cx, "String", node.name) != ""
      # e.size or e.strip on the payload of error(e), which was a String before it was an Error.
      help = "an Error is not a String: call #{node.name} on its text, e.message.#{node.name}"
    end

    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNKNOWN-FIELD",
        "\"#{T.written_type(T.name(target))}\" has no field \"#{node.name}\"",
        node.span,
        help,
      ),
    )
  end

  if State.private_fields(cx, T.name(target)).include?(node.name)
    return error(State.private_field(cx, st, T.name(target), node.name, node.name_span))
  end

  ok(State.Out(st: st, type: field.unwrap!.type))
end

# What the method is: "self", "text" (to_s) or "inspect" for a data value, the full name of a builtin, or "" when there
# is none.
def method_kind(cx: State.Cx, target: T.Type, kind: String, name: String) -> String
  if kind != ""
    found = Names.resolve_method(cx, kind, name)
    return found if found != ""
  end

  if name == "to_s" and CheckTypes.data?(cx, target)
    return "text"
  elsif name == "inspect" and CheckTypes.data?(cx, target)
    return "inspect"
  end

  ""
end

# The method on a receiver that is already checked. The resolution is recorded by the id of the node. `piped` is
# true for a pipe step (`x |> name()`), whose unknown name is CHECK-UNKNOWN-NAME.
def method_on(
  cx: State.Cx,
  target: State.Out,
  id: Int,
  target_node: Ast.Expr,
  name: String,
  args: List[Ast.Expr],
  named: List[Ast.NamedArg],
  span: Source.Span,
  piped: Bool,
  expected: T.Type,
) -> Result[State.Out]
  type = target.type
  kind = Names.receiver_kind(type)
  resolved = method_kind(cx, type, kind, name)
  if resolved == "" and piped
    help = unknown_method_help(cx, target.st, id, type, kind, name)
    return error(unknown_piped(cx, target.st, type, target_node, name, span, help))
  elsif resolved == ""
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
    return check_own_method(cx, target.st, id, resolved, type, name, args.size + named.size, span, expected)
  end

  typed = Ast.Expr.Typed(
    Ast.TypedTarget(id: Ast.expr_id(target_node), target: target_node, type: type, span: Ast.expr_span(target_node)),
  )

  call = Ast.Call(
    id: id,
    name: resolved,
    args: [typed].concat(args),
    piped: false,
    parenthesized: true,
    span: span,
    named: named,
  )

  st = State.record_resolved(target.st, id, State.Resolved.Call(resolved, type))
  Calls.check_call(cx, st, call, expected)
end

# to_s and inspect, and a to_s that is the receiver itself: they take no arguments and give a String (or the receiver).
def check_own_method(
  cx: State.Cx,
  st: State.St,
  id: Int,
  resolved: String,
  type: T.Type,
  name: String,
  count: Int,
  span: Source.Span,
  expected: T.Type,
) -> Result[State.Out]
  return error(State.fail(cx, st, "CHECK-ARITY", "\"#{name}\" takes no arguments", span)) if count > 0

  result = T.Type.String
  how = State.Resolved.Text(type)
  if resolved == "self"
    result = type
    how = State.Resolved.Self(type)
  elsif resolved == "inspect"
    how = State.Resolved.Inspect(type)
  end

  checked = try State.ensure(cx, st, result, expected, span)
  ok(State.Out(st: State.record_resolved(st, id, how), type: checked))
end

# `x |> name()` that the linker made a method call, because no function of the program has the name, and whose
# receiver has no such method either: CHECK-UNKNOWN-NAME, as for an unknown function. A step names only methods, so a
# field of the receiver is read or called with `.`; a variable of that name is called with .call, a function with a
# close name is likely the one meant, and otherwise `help` names the methods of the receiver.
def unknown_piped(
  cx: State.Cx,
  st: State.St,
  type: T.Type,
  target: Ast.Expr,
  name: String,
  span: Source.Span,
  help: String,
) -> String
  hint = help
  near = Help.near(name, cx.functions.keys, [])
  fields: List[Model.Named] = []
  if T.is?(type, "Struct")
    fields = CheckTypes.fields_of(cx, type)
  end

  field = Calls.find_field(fields, name)
  receiver = Calls.receiver_text(cx, target)
  if receiver == "" or receiver == "()" or receiver.length > 40 or receiver.include?("\n")
    receiver = "value"
  end

  if field.ok? and T.is?(field.unwrap!.type, "Fn")
    hint = "#{name} is an Fn field, which a pipe does not call; call it with #{receiver}.#{name}(...)"
  elsif field.ok?
    hint = "#{name} is a field, which a pipe does not read; read it with #{receiver}.#{name}"
  elsif State.lookup(st, name).some?
    hint = "#{name} is a variable, not a function; call it with #{name}.call(...)"
  elsif near != ""
    hint = near
  end

  State.fail_maybe(cx, st, "CHECK-UNKNOWN-NAME", "unknown function or method \"#{name}\"", span, hint)
end

# The help of CHECK-UNKNOWN-METHOD: a range that needs parentheses, then what is special about the receiver.
def unknown_method_help(cx: State.Cx, st: State.St, id: Int, target: T.Type, kind: String, name: String) -> String
  if st.range_chain.any? do |link: Int| link == id end and Names.resolve_method(cx, "Range", name) != ""
    return "a method call on a range needs parentheses: (a..b).#{name}"
  elsif name == "to_s" or name == "inspect"
    return (
      "only data values have to_s and inspect: numbers, Bool, String, nil, JSON.Value, ranges, and lists, maps, " +
      "sets, Results, structs and enums of those"
    )
  elsif T.error?(target) and Names.resolve_method(cx, "String", name) != ""
    # A String method on the payload of error(e), which was a String before it was an Error.
    return "an Error is not a String: call #{name} on its text, e.message.#{name}"
  elsif T.error?(target) and kind != ""
    return kind_help(cx, target, kind, name)
  elsif T.is?(target, "Struct")
    return struct_help(cx, target, name)
  elsif name == "with"
    return "with copies a struct with some fields changed; the value before .with must be a struct"
  elsif kind != ""
    return kind_help(cx, target, kind, name)
  elsif CheckTypes.data?(cx, target)
    return Help.near(name, ["to_s", "inspect"], [])
  end

  ""
end

# A struct has no methods: the help says what the name could be instead.
def struct_help(cx: State.Cx, target: T.Type, name: String) -> String
  fields = State.shown_fields(cx, T.name(target), CheckTypes.fields_of(cx, target))
  field = Calls.find_field(fields, name)
  if field.ok?
    # A field that a function shares its name with is the likelier mistake, so it comes first.
    hint = "#{name} is a field of type #{T.to_text(field.unwrap!.type)}, not a function; call only an Fn field"
    return hint + "; or call #{name}(...) with the struct as an argument" if cx.functions.has_key?(name)

    return hint
  elsif cx.functions.has_key?(name)
    return "structs have no methods; call #{name}(...) with the struct as an argument"
  elsif name == "with"
    # No did-you-mean here: a field close to "with" is not a typo of it.
    return "with needs the fields to change, as in .with(field: value); #{Help.field_list(fields)}"
  end

  "structs have no methods; #{Help.field_help(name, fields)}"
end

# The help for a method another language has, a close name, or the methods the kind has.
def kind_help(cx: State.Cx, target: T.Type, kind: String, name: String) -> String
  foreign = Names.foreign_method_help(cx, kind, name)
  return foreign if foreign != ""

  names = method_names(cx, target, kind)
  guess = Help.near(name, names, [])
  return guess if guess != ""

  "#{T.to_text(target)} methods: #{names.sort.join(", ")}"
end

# The methods of the kind, with to_s and inspect for a data value.
def method_names(cx: State.Cx, target: T.Type, kind: String) -> List[String]
  names = Names.method_names(cx, kind)
  if CheckTypes.data?(cx, target)
    names = names.concat(
      ["to_s", "inspect"].filter do |own: String| !names.any? do |known: String| known == own end end,
    )
  end

  names
end

# True for a File.foreach call written directly as the receiver: .each on it is the one job of File.each_line
# (docs/grammar/06b-builtins.md, `Lazy[T]`, one way per job). A Lazy held in a variable is not followed.
def foreach_call?(target: Ast.Expr) -> Bool
  case target
    Ast.Expr.Call(call) -> call.name == "File.foreach"
    _ -> false
  end
end
