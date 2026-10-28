## A call of a builtin: the form that takes this many arguments, a block only
## where the last parameter is a function, then the rule of the builtin. The List, Map, Set, Task and Channel rules are
## in check_list.agc and check_collections.agc; the rest are here.

import Model from "../catalog/builtin_model"
import Builtins from "../catalog/builtins"
import Failure from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import Args from "check_args"
import Collections from "check_collections"
import Lists from "check_list"
import PreludeCalls from "check_prelude"
import State from "check_state"
import CheckTypes from "check_types"
import Defaults from "defaults"
import RubyForm from "ruby_form"

## Checks a call of the builtin entry (the first form of the name). expected is the type the context wants, Unknown
## when none.
export def check_builtin_call(
  cx: State.Cx,
  st: State.St,
  node: Ast.Call,
  expected: T.Type,
  entry: Model.Builtin,
) -> Result[State.Out]
  selected = Builtins.form_for(entry, node.args.size)
  if !selected.ok?
    # A block after the last argument of a builtin that takes none (each_slice) is a block with no target.
    try block_without_target(cx, st, node, entry)
    return error(arity_failure(cx, st, node, entry))
  end

  form = selected.unwrap!
  try check_block_target(cx, st, node, form)
  site = State.Site(node: node, args: node.args, selected: form, expected: expected)
  return check_rule(cx, st, site, form.rule)
end

## CHECK-TYPE-MISMATCH unless the type can be printed or interpolated (it has to_s).
export def ensure_printable(cx: State.Cx, st: State.St, type: T.Type, span: Source.Span) -> Result[Bool]
  if !CheckTypes.data?(cx, type)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-TYPE-MISMATCH",
        "#{T.to_text(type)} has no to_s, so it cannot be printed or interpolated",
        span,
        (
          "only data values have to_s: numbers, Bool, String, nil, Json, ranges, and lists, maps, sets, Results, " +
          "structs and enums of those"
        ),
      ),
    )
  end

  return ok(true)
end

# CHECK-ARITY: no form of the builtin takes this many arguments. The note is the signature of every form. A call
# written in method form (the receiver is the first argument, a Typed node) names the Ruby method and counts the
# arguments after the receiver: `s.include?` expects 1, not 2.
def arity_failure(cx: State.Cx, st: State.St, node: Ast.Call, entry: Model.Builtin) -> String
  skipped = 0
  name = entry.name
  if method_form?(node) and RubyForm.method_name(entry.name) != ""
    skipped = 1
    name = RubyForm.shown(entry.name)
  end

  # Forms of one arity (JSON.decode of text or of a Json) count once.
  counts: List[String] = []
  for form in [entry].concat(entry.alternatives)
    text = Builtins.arity_text(form, skipped)
    if !counts.any? do |seen: String| seen == text end
      counts = counts.push(text)
    end
  end

  expected = counts.join(" or ")
  message = "\"#{name}\" expects #{expected} argument(s), found #{node.args.size - skipped}"
  base = Failure.problem(cx.file, st.signature, "CHECK-ARITY", message, node.span, State.hint_of(""))
  return Failure.pack(base.with(callee: Builtins.signature(entry)))
end

# True for a call that a method call became: its first argument is the typed receiver.
def method_form?(node: Ast.Call) -> Bool
  if node.args.size == 0
    return false
  end

  case node.args[0]
    Ast.Expr.Typed(found) -> return true
    _ -> return false
  end
end

# CHECK-BLOCK-TARGET when the call has one argument more than a form takes and that last argument is a block, so the
# block was meant for a function parameter the form does not have.
def block_without_target(cx: State.Cx, st: State.St, node: Ast.Call, entry: Model.Builtin) -> Result[Bool]
  if node.args.size == 0
    return ok(true)
  end

  last = node.args[node.args.size - 1]
  without = Builtins.form_for(entry, node.args.size - 1)
  case last
    Ast.Expr.BlockLit(block) ->
      if without.ok?
        return error(
          State.fail_help(
            cx,
            st,
            "CHECK-BLOCK-TARGET",
            block_target_message(entry.name),
            block.span,
            block_target_help(entry.name),
          ),
        )
      end

    _ -> return ok(true)
  end

  return ok(true)
end

# A block as the last argument needs a function as the last parameter.
def check_block_target(cx: State.Cx, st: State.St, node: Ast.Call, form: Model.Builtin) -> Result[Bool]
  if node.args.size == 0
    return ok(true)
  end

  last = node.args[node.args.size - 1]
  case last
    Ast.Expr.BlockLit(block) ->
      if !T.is?(form.parameters[form.parameters.size - 1].type, "Fn")
        return error(
          State.fail_help(
            cx,
            st,
            "CHECK-BLOCK-TARGET",
            block_target_message(form.name),
            block.span,
            block_target_help(form.name),
          ),
        )
      end

    _ -> return ok(true)
  end

  return ok(true)
end

# The message of a block given to a builtin that takes none. Task.spawn takes a block, but alone.
def block_target_message(name: String) -> String
  if name == "Task.spawn"
    return "Task.spawn got a function reference and a block: it takes one of them, not both"
  end

  return "\"#{name}\" does not take a block: its last parameter is not a function"
end

# The help of a block given to a builtin that takes none: each_slice returns the slices, which each then walks.
def block_target_help(name: String) -> String
  if name == "List.each_slice"
    return "each_slice returns the slices and takes no block: xs.each_slice(2).each do |pair| ... end"
  end

  if name == "Task.spawn"
    return "Task.spawn takes a block or a function reference, not both: Task.spawn do ... end or Task.spawn(&f, arg)"
  end

  return "a block is only allowed when the last parameter is a function (Fn[...])"
end

# The rule of the builtin, which says how its arguments are checked and what type the call has.
def check_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.Plain -> return check_plain(cx, st, site)
    Model.Rule.Show -> return check_show(cx, st, site)
    Model.Rule.Identity -> return check_identity(cx, st, site)
    Model.Rule.Ok -> return check_ok(cx, st, site)
    Model.Rule.OkVoid -> return ok(State.Out(st: st, type: T.Type.Result(T.Type.Void)))
    Model.Rule.Error -> return check_error(cx, st, site)
    Model.Rule.JsonDecode -> return check_json_type(cx, st, site, true)
    Model.Rule.JsonSchema -> return check_json_type(cx, st, site, false)
    Model.Rule.JsonEncode -> return check_json_encode(cx, st, site, false)
    Model.Rule.JsonFrom -> return check_json_encode(cx, st, site, true)
    Model.Rule.JsonCodec -> return check_json_codec(cx, st, site)
    Model.Rule.CodecDecode -> return check_codec_decode(cx, st, site)
    Model.Rule.CodecEncode -> return check_codec_encode(cx, st, site)
    Model.Rule.TestEq -> return check_test_eq(cx, st, site)
    Model.Rule.Prelude -> return PreludeCalls.check_prelude_call(cx, st, site)
    _ -> return check_result_rule(cx, st, site, rule)
  end
end

# A builtin with no rule: each argument against its parameter.
def check_plain(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  form = site.selected
  count = site.args.size
  shape = Defaults.Shape(required: count, total: count, fn_last: false)
  if Builtins.defaulted?(form)
    shape = Defaults.builtin_shape(form)
  end

  current = st
  index = 0
  while index < count and index < form.parameters.size
    param = Defaults.param_of(shape, count, index)
    out = try State.expr(cx, current, site.args[index], form.parameters[param].type)
    current = out.st
    index += 1
  end

  return ok(State.Out(st: current, type: form.result))
end

# puts and print: any value that can be printed.
def check_show(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  try ensure_printable(cx, out.st, out.type, Ast.expr_span(site.args[0]))
  return ok(State.Out(st: out.st, type: T.Type.Void))
end

# IO.inspect: any value, except one whose type holds a JSON.Codec, which has no inspect (a codec is its struct's name
# at run time, and would print as that String). A T of a generic body is not looked into: it may still be a codec.
def check_identity(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], site.expected)
  if Collections.holds_codec?(cx, out.type)
    return error(
      State.fail_help(
        cx,
        out.st,
        "CHECK-TYPE-MISMATCH",
        "#{T.to_text(out.type)} cannot be inspected: a JSON.Codec has no inspect",
        Ast.expr_span(site.args[0]),
        "inspect the values the codec reads or writes instead",
      ),
    )
  end

  return ok(out)
end

def check_ok(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.only_result_item(site.expected))
  return ok(State.Out(st: out.st, type: T.Type.Result(out.type)))
end

# error(message) needs the Result type from its context, except while a block is probed for its result type.
def check_error(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  message = try State.expr(cx, st, site.args[0], T.Type.String)
  expected = site.expected
  span = site.node.span
  if !T.unknown?(expected) and !T.is?(expected, "Result")
    return error(State.mismatch(cx, message.st, expected, T.Type.Result(T.Type.Var("T")), span))
  end

  if T.unknown?(expected) and message.st.probe
    return ok(State.Out(st: message.st, type: T.Type.Result(T.Type.Unknown)))
  end

  if T.unknown?(expected)
    return error(
      State.fail_help(
        cx,
        message.st,
        "CHECK-RESULT-TYPE",
        "an error needs an expected Result type",
        span,
        "add a Result[T] annotation, for example r: Result[Int] = error(message)",
      ),
    )
  end

  return ok(State.Out(st: message.st, type: expected))
end

# JSON.decode(source, Type) and JSON.schema(Type): the type argument is a struct name whose fields can all be
# decoded. The source of JSON.decode is JSON text (String) or a Json value.
def check_json_type(cx: State.Cx, st: State.St, site: State.Site, decode: Bool) -> Result[State.Out]
  current = st
  target = site.args[0]
  if decode
    current = try check_decode_source(cx, current, site.args[0])
    target = site.args[1]
  end

  type = try json_struct(cx, current, target)
  if decode
    return ok(State.Out(st: current, type: T.Type.Result(type)))
  end

  return ok(State.Out(st: current, type: T.Type.Json))
end

# JSON.codec(Type): the codec of the struct, with the type argument JSON.decode takes.
def check_json_codec(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  type = try json_struct(cx, st, site.args[0])
  return ok(State.Out(st: st, type: T.Type.Codec(type)))
end

# codec.decode(source): JSON.decode into the struct of the codec, from JSON text or a Json value. The receiver of a
# codec method is a JSON.Codec: the rows are reached only as methods of one, since the parser has no function form of
# a name with two dots (check_method gives the help for JSON.Codec.decode(...)).
def check_codec_decode(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  codec = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  current = try check_decode_source(cx, codec.st, site.args[1])
  return ok(State.Out(st: current, type: T.Type.Result(T.item(codec.type))))
end

# codec.encode(value) and codec.from(value): a value of the struct of the codec, which can be written as JSON because
# the struct can be decoded. The form gives the result type (String or Json).
def check_codec_encode(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  codec = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  value = try State.expr(cx, codec.st, site.args[1], T.item(codec.type))
  return ok(State.Out(st: value.st, type: site.selected.result))
end

# The source of a decode, which is JSON text (String) or a Json value.
def check_decode_source(cx: State.Cx, st: State.St, source: Ast.Expr) -> Result[State.St]
  out = try State.expr(cx, st, source, T.Type.Unknown)
  if !T.is?(out.type, "String") and !T.is?(out.type, "Json")
    return error(decode_source_mismatch(cx, out.st, out.type, Ast.expr_span(source)))
  end

  return ok(out.st)
end

# The struct a JSON type argument names, which must be a struct name whose fields can all be decoded.
def json_struct(cx: State.Cx, st: State.St, target: Ast.Expr) -> Result[T.Type]
  case target
    Ast.Expr.TypeName(node) -> return json_target(cx, st, node)
    _ -> return error(
      State.fail(
        cx,
        st,
        "CHECK-TYPE-MISMATCH",
        "JSON type argument requires a struct name",
        Ast.expr_span(target),
      ),
    )
  end
end

# CHECK-TYPE-MISMATCH for a JSON.decode source that is neither JSON text nor a Json value.
def decode_source_mismatch(cx: State.Cx, st: State.St, actual: T.Type, span: Source.Span) -> String
  found = T.to_text(actual)
  message = "expected String or Json, found #{found}"
  base = Failure.problem(cx.file, st.signature, "CHECK-TYPE-MISMATCH", message, span, State.hint_of(""))
  return Failure.pack(base.with(expected: "String or Json", actual: found))
end

def json_target(cx: State.Cx, st: State.St, node: Ast.TypeName) -> Result[T.Type]
  ref = Ast.TypeRef(id: node.id, name: node.name, args: [], span: node.span)
  type = try CheckTypes.resolve_type(cx, st, ref, false)
  try json_field_place(cx, st, type, "decode target", node.span)
  if !T.is?(type, "Struct") or !CheckTypes.decodable?(cx, type)
    return error(State.fail(cx, st, "CHECK-NOT-DECODABLE", "target contains types that cannot be decoded", node.span))
  end

  return ok(type)
end

# JSON.encode and JSON.from: any value that can be written as JSON.
def check_json_encode(cx: State.Cx, st: State.St, site: State.Site, from: Bool) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  try json_field_place(cx, out.st, out.type, "encode argument", Ast.expr_span(site.args[0]))
  if !CheckTypes.encodable?(cx, out.type)
    return error(
      State.fail(
        cx,
        out.st,
        "CHECK-NOT-ENCODABLE",
        "cannot JSON.encode #{T.to_text(out.type)} or its nested types",
        Ast.expr_span(site.args[0]),
      ),
    )
  end

  if from
    return ok(State.Out(st: out.st, type: T.Type.Json))
  end

  return ok(State.Out(st: out.st, type: T.Type.String))
end

# CHECK-JSON-FIELD-PLACE when a JSON builtin's target or argument has a JsonField that is not the direct type of a
# struct field. kind names the place of the whole type.
def json_field_place(cx: State.Cx, st: State.St, type: T.Type, kind: String, span: Source.Span) -> Result[Void]
  place = CheckTypes.json_field_place(cx, type, false, kind, "")
  if place == ""
    return ok()
  end

  return error(
    State.fail_help(
      cx,
      st,
      "CHECK-JSON-FIELD-PLACE",
      "JsonField is only allowed as the direct type of a struct field, not as the #{place}",
      span,
      "JsonField tells an absent key from null, so it belongs to a struct field: name: JsonField[String]",
    ),
  )
end

# Test.eq: two values of one type that has equality.
def check_test_eq(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  actual = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  wanted = try State.expr(cx, actual.st, site.args[1], actual.type)
  if !T.same?(actual.type, wanted.type)
    return error(State.mismatch(cx, wanted.st, actual.type, wanted.type, Ast.expr_span(site.args[1])))
  end

  if !CheckTypes.data?(cx, actual.type)
    return error(
      State.fail_help(
        cx,
        wanted.st,
        "CHECK-TYPE-MISMATCH",
        "Test.eq needs a type with equality, found #{T.to_text(actual.type)}",
        Ast.expr_span(site.args[0]),
        (
          "Test.eq compares numbers, Bool, String, nil, ranges, Json, and lists, maps, sets, Results, " +
          "structs and enums of those"
        ),
      ),
    )
  end

  return ok(State.Out(st: wanted.st, type: T.Type.Result(T.Type.Void)))
end

def check_result_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.TestResult ->
      target = try Args.result_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.Result(T.Type.Void)))
    Model.Rule.ResultOk ->
      target = try Args.result_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.Bool))
    Model.Rule.ResultMessage ->
      target = try Args.result_argument(cx, st, site, T.Type.Unknown)
      return ok(State.Out(st: target.st, type: T.Type.String))
    Model.Rule.ResultUnwrap ->
      target = try Args.result_argument(cx, st, site, T.result_of(site.expected))
      return ok(State.Out(st: target.st, type: T.item(target.type)))
    Model.Rule.ResultDefault ->
      default = try State.expr(cx, st, site.args[1], site.expected)
      target = try Args.result_argument(cx, default.st, site, T.Type.Result(default.type))
      return ok(State.Out(st: target.st, type: default.type))
    _ -> return check_other_rule(cx, st, site, rule)
  end
end

# The rules of the Task, Channel, Map and Set builtins, then of the List builtins.
def check_other_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  if list_rule?(rule)
    return Lists.check_list_rule(cx, st, site, rule)
  end

  return Collections.check_collection_rule(cx, st, site, rule)
end

def list_rule?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.ListSize -> return true
    Model.Rule.ListReverse -> return true
    Model.Rule.ListSort -> return true
    Model.Rule.ListSortBy -> return true
    Model.Rule.ListConcat -> return true
    Model.Rule.ListCount -> return true
    Model.Rule.ListAt -> return true
    Model.Rule.ListAppend -> return true
    Model.Rule.ListSet -> return true
    Model.Rule.ListRepeat -> return true
    Model.Rule.ListMap -> return true
    Model.Rule.ListFilter -> return true
    Model.Rule.ListReduce -> return true
    Model.Rule.ListEach -> return true
    Model.Rule.ListAny -> return true
    Model.Rule.ListAll -> return true
    _ -> return false
  end
end
