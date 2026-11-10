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
import {PROCESS_OPTIONS_HELP} from "check_help"
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
  selected = Builtins.form_for_call(entry, node.args.size, Ast.block_call?(node))
  if !selected.ok?
    # A block after the last argument of a builtin that takes none (each_slice) is a block with no target.
    try block_without_target(cx, st, node, entry)
    return error(arity_failure(cx, st, node, entry))
  end

  form = selected.unwrap!
  try check_block_target(cx, st, node, form)
  site = State.Site(node: node, args: node.args, selected: form, expected: expected)
  check_rule(cx, st, site, form.rule)
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
        "only data values have to_s: numbers, Bool, String, nil, Json, ranges, and lists, maps, sets, Results, " +
        "structs and enums of those",
      ),
    )
  end

  ok(true)
end

## Type.codec: the codec of the struct or enum named by the type name, which must be a type JSON.decode takes.
export def check_codec_of(cx: State.Cx, st: State.St, node: Ast.TypeName) -> Result[T.Type]
  ok(T.Type.Codec(try json_target(cx, st, node, "codec requires a struct or enum name")))
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
  base = Failure.problem(
    cx.file,
    st.signature,
    "CHECK-ARITY",
    message,
    node.span,
    State.hint_of(old_form_help(name, node)),
  )

  Failure.pack(base.with(callee: Builtins.signature(entry)))
end

# The help for a call in a form that a builtin had before (TLS.listen with the PEM paths before contexts, 19a, and the
# spawns with positional options before Process.Options), or "".
def old_form_help(name: String, node: Ast.Call) -> String
  spawns = ["Process.spawn", "Process.spawn_captured", "Process.spawn_channel"]
  return PROCESS_OPTIONS_HELP if spawns.include?(name) and node.args.size > 3

  if name == "TLS.listen" and node.args.size == 4
    return (
      "a TlsContext holds the PEM files: build one with " +
      "TLS.server_context(TlsServerOptions(cert_file: c, key_file: k))"
    )
  end

  ""
end

# True for a call that a method call became: its first argument is the typed receiver.
def method_form?(node: Ast.Call) -> Bool
  return false if node.args.size == 0

  case node.args[0]
    Ast.Expr.Typed(_) -> true
    _ -> false
  end
end

# CHECK-BLOCK-TARGET when the call has one argument more than a form takes and that last argument is a block, so the
# block was meant for a function parameter the form does not have.
def block_without_target(cx: State.Cx, st: State.St, node: Ast.Call, entry: Model.Builtin) -> Result[Bool]
  return ok(true) if node.args.size == 0

  last = node.args[node.args.size - 1]
  without = Builtins.form_without_block(entry, node.args.size - 1)
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

  ok(true)
end

# A block as the last argument needs a function as the last parameter.
def check_block_target(cx: State.Cx, st: State.St, node: Ast.Call, form: Model.Builtin) -> Result[Bool]
  return ok(true) if node.args.size == 0

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

  ok(true)
end

# The message of a block given to a builtin that takes none. Task.spawn takes a block, but alone.
def block_target_message(name: String) -> String
  return "Task.spawn got a function reference and a block: it takes one of them, not both" if name == "Task.spawn"

  "\"#{name}\" does not take a block: its last parameter is not a function"
end

# The help of a block given to a builtin that takes none: each_slice returns the slices, which each then walks, and
# index takes a value, while find_index takes the block.
def block_target_help(name: String) -> String
  if name == "List.each_slice"
    return "each_slice returns the slices and takes no block: xs.each_slice(2).each do |pair| ... end"
  end

  if name == "List.index"
    return "index takes a value, not a block: xs.index(value), or xs.find_index do |x| ... end for a test"
  end

  if name == "Task.spawn"
    return "Task.spawn takes a block or a function reference, not both: Task.spawn do ... end or Task.spawn(&f, arg)"
  end

  "a block is only allowed when the last parameter is a function (Fn[...])"
end

# The rule of the builtin, which says how its arguments are checked and what type the call has.
def check_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.Plain -> check_plain(cx, st, site)
    Model.Rule.Show -> check_show(cx, st, site)
    Model.Rule.Identity -> check_identity(cx, st, site)
    Model.Rule.Ok -> check_ok(cx, st, site)
    Model.Rule.OkVoid -> ok(State.Out(st: st, type: T.Type.Result(T.Type.Void)))
    Model.Rule.Error -> check_error(cx, st, site)
    Model.Rule.OptionalSome -> check_some(cx, st, site)
    Model.Rule.OptionalNone -> check_none(cx, st, site)
    Model.Rule.JsonDecode -> check_json_type(cx, st, site, true)
    Model.Rule.JsonSchema -> check_json_type(cx, st, site, false)
    Model.Rule.JsonEncode -> check_json_encode(cx, st, site, false)
    Model.Rule.JsonFrom -> check_json_encode(cx, st, site, true)
    Model.Rule.CodecDecode -> check_codec_decode(cx, st, site)
    Model.Rule.CodecEncode -> check_codec_encode(cx, st, site)
    Model.Rule.CodecMembers -> check_codec_members(cx, st, site)
    Model.Rule.TestEq -> check_test_eq(cx, st, site)
    Model.Rule.Prelude -> PreludeCalls.check_prelude_call(cx, st, site)
    _ -> check_result_rule(cx, st, site, rule)
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

  ok(State.Out(st: current, type: form.result))
end

# puts and print: any value that can be printed.
def check_show(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  try ensure_printable(cx, out.st, out.type, Ast.expr_span(site.args[0]))
  ok(State.Out(st: out.st, type: T.Type.Void))
end

# IO.inspect: any value, except one whose type holds a Codec, which has no inspect (a codec is a record of the name
# and the members of its type at run time, and has no text of its own). A T of a generic body is not looked into: it
# may still be a codec.
def check_identity(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], site.expected)
  if Collections.holds_codec?(cx, out.type)
    return error(
      State.fail_help(
        cx,
        out.st,
        "CHECK-TYPE-MISMATCH",
        "#{T.to_text(out.type)} cannot be inspected: a Codec has no inspect",
        Ast.expr_span(site.args[0]),
        "inspect the values the codec reads or writes instead",
      ),
    )
  end

  ok(out)
end

# ok(value): the type is built from the value's checked type, which top_names (lowering.agc) and matches_expected?
# (check_expr.agc) rely on.
def check_ok(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.only_result_item(site.expected))
  ok(State.Out(st: out.st, type: T.Type.Result(out.type)))
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

  ok(State.Out(st: message.st, type: expected))
end

# some(value): the expected Optional gives the value its expected type. The type is built from the value's checked
# type, which top_names (lowering.agc) and matches_expected? (check_expr.agc) rely on.
def check_some(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.only_optional_item(site.expected))
  ok(State.Out(st: out.st, type: T.Type.Optional(out.type)))
end

# none needs the Optional type from its context, except while a block is probed for its result type, as error(...)
# does.
def check_none(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  expected = site.expected
  span = site.node.span
  if !T.unknown?(expected) and !T.is?(expected, "Optional")
    return error(State.mismatch(cx, st, expected, T.Type.Optional(T.Type.Var("T")), span))
  end

  return ok(State.Out(st: st, type: T.Type.Optional(T.Type.Unknown))) if T.unknown?(expected) and st.probe

  if T.unknown?(expected)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-OPTIONAL-TYPE",
        "none needs an expected Optional type",
        span,
        "add an Optional[T] annotation, for example age: Optional[Int] = none",
      ),
    )
  end

  ok(State.Out(st: st, type: expected))
end

# JSON.decode(source, Type) and JSON.schema(Type): the type argument is a struct or enum name whose fields or payloads
# can all be decoded, or for JSON.decode also a List[T] or Map[String, T] of such a T. The source of JSON.decode is
# JSON text (String) or a Json value.
def check_json_type(cx: State.Cx, st: State.St, site: State.Site, decode: Bool) -> Result[State.Out]
  current = st
  target = site.args[0]
  if decode
    current = try check_decode_source(cx, current, site.args[0])
    target = site.args[1]
  end

  type = try json_type(cx, current, target, decode)
  # The lowering names the target by this type: an alias resolved, a List or Map whole (Lowering.json_targets).
  current = State.record_type(current, Ast.expr_id(target), type)
  return ok(State.Out(st: current, type: T.Type.Result(type))) if decode

  ok(State.Out(st: current, type: T.Type.Json))
end

# codec.decode(source): JSON.decode into the struct of the codec, from JSON text or a Json value. The receiver of a
# codec method is a Codec: the rows are reached only as methods of one.
def check_codec_decode(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  codec = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  current = try check_decode_source(cx, codec.st, site.args[1])
  ok(State.Out(st: current, type: T.Type.Result(T.item(codec.type))))
end

# codec.members: the fields of the struct of the codec, as T.members gives them.
def check_codec_members(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  codec = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  ok(State.Out(st: codec.st, type: site.selected.result))
end

# codec.encode(value) and codec.from(value): a value of the struct of the codec, which can be written as JSON because
# the struct can be decoded. The form gives the result type (String or Json).
def check_codec_encode(cx: State.Cx, st: State.St, site: State.Site) -> Result[State.Out]
  codec = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  value = try State.expr(cx, codec.st, site.args[1], T.item(codec.type))
  ok(State.Out(st: value.st, type: site.selected.result))
end

# The source of a decode, which is JSON text (String) or a Json value.
def check_decode_source(cx: State.Cx, st: State.St, source: Ast.Expr) -> Result[State.St]
  out = try State.expr(cx, st, source, T.Type.Unknown)
  if !T.is?(out.type, "String") and !T.is?(out.type, "Json")
    return error(decode_source_mismatch(cx, out.st, out.type, Ast.expr_span(source)))
  end

  ok(out.st)
end

# The struct or enum a JSON type argument names, which must be a name whose fields or payloads can all be decoded. A
# List[T] or Map[String, T], written so or through an alias, is a target of JSON.decode only: JSON.schema describes a
# named type.
def json_type(cx: State.Cx, st: State.St, target: Ast.Expr, decode: Bool) -> Result[T.Type]
  case target
    Ast.Expr.TypeName(node) ->
      refusal = ""
      if !decode
        refusal = "JSON.schema requires a struct or enum name"
      end

      json_target(cx, st, node, refusal)
    _ ->
      message = "JSON type argument requires a struct or enum name"
      error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", message, Ast.expr_span(target)))
  end
end

# CHECK-TYPE-MISMATCH for a JSON.decode source that is neither JSON text nor a Json value.
def decode_source_mismatch(cx: State.Cx, st: State.St, actual: T.Type, span: Source.Span) -> String
  found = T.to_text(actual)
  message = "expected String or Json, found #{found}"
  base = Failure.problem(cx.file, st.signature, "CHECK-TYPE-MISMATCH", message, span, State.hint_of(""))
  Failure.pack(base.with(expected: "String or Json", actual: found))
end

# The type a JSON target names. refusal is the CHECK-TYPE-MISMATCH message for a List or Map target, or "" when the
# caller takes one (JSON.decode); it comes before the decodable check, so a List of anything is refused the same way.
def json_target(cx: State.Cx, st: State.St, node: Ast.TypeName, refusal: String) -> Result[T.Type]
  ref = Ast.TypeRef(id: node.id, name: node.name, args: node.args, span: node.span)
  type = try CheckTypes.resolve_type(cx, st, ref, false)
  return error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", refusal, node.span)) if container?(type) and refusal != ""

  try json_field_place(cx, st, type, "decode target", node.span)
  named = T.is?(type, "Struct") or T.is?(type, "Enum")
  if !(named or container?(type)) or !CheckTypes.decodable?(cx, type)
    return error(
      State.fail_maybe(
        cx,
        st,
        "CHECK-NOT-DECODABLE",
        "target contains types that cannot be decoded",
        node.span,
        json_refusal_help(cx, type, "decode"),
      ),
    )
  end

  ok(type)
end

# True for a List or Map JSON target, which only JSON.decode takes.
def container?(type: T.Type) -> Bool = T.is?(type, "List") or T.is?(type, "Map")

# The help of a JSON builtin that refuses a type with a JsonField of an Optional or a Bytes inside, or "": JSON has no
# byte type, so the bytes are written as Base64 text and read back from it.
def json_refusal_help(cx: State.Cx, type: T.Type, verb: String) -> String
  if CheckTypes.optional_json_field_inside?(cx, type)
    return (
      "JsonField[Optional[T]] would write null for JsonField.Null and for none; use Optional[T], or JsonField[T] to " +
      "tell a missing key from null"
    )
  end

  return "" if !CheckTypes.bytes_inside?(cx, type)

  return "JSON has no byte type; encode it first: Base64.strict_encode64(b)" if verb == "encode"

  if T.is?(type, "Bytes")
    return "JSON has no byte type; decode a String and convert it with Base64.strict_decode64(text)"
  end

  "JSON has no byte type; use a String field and decode it with Base64.strict_decode64(text)"
end

# JSON.encode and JSON.from: any value that can be written as JSON. In a generic body a type with type variables is
# allowed when some binding makes it encodable: what it needs of the variables is recorded for the callers
# (State.JsonUse.Need), which check it where they bind them (CheckTypes.check_json_needs).
def check_json_encode(cx: State.Cx, st: State.St, site: State.Site, from: Bool) -> Result[State.Out]
  out = try State.expr(cx, st, site.args[0], T.Type.Unknown)
  try json_field_place(cx, out.st, out.type, "encode argument", Ast.expr_span(site.args[0]))
  needs: Optional[List[T.Type]] = none
  if !cx.prelude and CheckTypes.has_variables?(out.type)
    needs = CheckTypes.encode_needs(cx, out.type)
  end

  if needs.some?
    current = out.st
    for need in needs.unwrap!
      current = State.use_json(current, State.JsonUse.Need(need))
    end

    out = out.with(st: current)
  elsif !CheckTypes.encodable?(cx, out.type)
    return error(
      State.fail_maybe(
        cx,
        out.st,
        "CHECK-NOT-ENCODABLE",
        "cannot JSON.encode #{T.to_text(out.type)} or its nested types",
        Ast.expr_span(site.args[0]),
        json_refusal_help(cx, out.type, "encode"),
      ),
    )
  end

  return ok(State.Out(st: out.st, type: T.Type.Json)) if from

  ok(State.Out(st: out.st, type: T.Type.String))
end

# CHECK-JSON-FIELD-PLACE when a JSON builtin's target or argument has a JsonField that is not the direct type of a
# struct field. kind names the place of the whole type.
def json_field_place(cx: State.Cx, st: State.St, type: T.Type, kind: String, span: Source.Span) -> Result[Void]
  place = CheckTypes.json_field_place(cx, type, false, kind, "")
  return ok() if place == ""

  error(
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
        "Test.eq compares numbers, Bool, String, nil, ranges, Json, and lists, maps, sets, Results, " +
        "structs and enums of those",
      ),
    )
  end

  ok(State.Out(st: wanted.st, type: T.Type.Result(T.Type.Void)))
end

def check_result_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  case rule
    Model.Rule.TestResult ->
      target = try Args.result_argument(cx, st, site, T.Type.Unknown)
      ok(State.Out(st: target.st, type: T.Type.Result(T.Type.Void)))
    Model.Rule.ResultOk ->
      target = try Args.result_argument(cx, st, site, T.Type.Unknown)
      ok(State.Out(st: target.st, type: T.Type.Bool))
    Model.Rule.ResultMessage ->
      target = try Args.result_argument(cx, st, site, T.Type.Unknown)
      ok(State.Out(st: target.st, type: T.Type.String))
    Model.Rule.ResultUnwrap ->
      target = try Args.result_argument(cx, st, site, T.result_of(site.expected))
      ok(State.Out(st: target.st, type: T.item(target.type)))
    Model.Rule.ResultDefault ->
      default = try State.expr(cx, st, site.args[1], site.expected)
      target = try Args.result_argument(cx, default.st, site, T.Type.Result(default.type))
      ok(State.Out(st: target.st, type: default.type))
    _ -> check_other_rule(cx, st, site, rule)
  end
end

# The rules of the Task, Channel, Map and Set builtins, then of the List builtins.
def check_other_rule(cx: State.Cx, st: State.St, site: State.Site, rule: Model.Rule) -> Result[State.Out]
  return Lists.check_list_rule(cx, st, site, rule) if list_rule?(rule)

  Collections.check_collection_rule(cx, st, site, rule)
end

def list_rule?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.ListSize -> true
    Model.Rule.ListReverse -> true
    Model.Rule.ListSort -> true
    Model.Rule.ListSortBy -> true
    Model.Rule.ListConcat -> true
    Model.Rule.ListCount -> true
    Model.Rule.ListAt -> true
    Model.Rule.ListAppend -> true
    Model.Rule.ListSet -> true
    Model.Rule.ListRepeat -> true
    Model.Rule.ListMap -> true
    Model.Rule.ListFilter -> true
    Model.Rule.ListReduce -> true
    Model.Rule.ListEach -> true
    Model.Rule.ListAny -> true
    Model.Rule.ListAll -> true
    _ -> false
  end
end
