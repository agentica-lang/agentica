## Calls and constructions: a call of a builtin or of a
## function of the program, an enum variant, a struct construction and a struct update.

import Model from "../catalog/builtin_model"
import Builtins from "../catalog/builtins"
import {ENTRIES, PRELUDE_ONLY, PUBLIC_NAMES, RECORDS} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import Help from "check_help"
import Names from "check_names"
import Rules from "check_rules"
import State from "check_state"
import Stmt from "check_stmt"
import Types from "check_types"
import Defaults from "defaults"

# What checking the arguments of a variant learned: the state and the type arguments found.
struct Inferred
  st: State.St
  substitutions: Map[String, T.Type]
end

# The names given in a construction or an update, the state after checking their values, and the type arguments of a
# generic struct that the values showed.
struct Fields
  st: State.St
  seen: Set[String]
  substitutions: Map[String, T.Type]
end

## Checks a call written by name: a builtin (and, for a piped call, that its method form is not the better one) or a
## function of the program.
export def check_call(cx: State.Cx, st: State.St, node: Ast.Call, expected: T.Type) -> Result[State.Out]
  entry = ENTRIES.get(node.name)
  if !entry.ok? or (PRELUDE_ONLY.include?(node.name) and !cx.prelude)
    return check_plain_call(cx, st, node, expected)
  end

  out = try Rules.check_builtin_call(cx, st, node, expected, entry.unwrap!)
  if node.piped
    try check_pipe_method(cx, out.st, node, entry.unwrap!)
  end

  return ok(out)
end

## Checks Enum.Variant(args): the arguments against the payload types, with the enum's type arguments taken from the
## expected type or from the arguments. named is the arguments written with names, which a variant does not take.
export def check_enum_constructor(
  cx: State.Cx,
  st: State.St,
  enum_name: String,
  variant_name: String,
  args: List[Ast.Expr],
  named: Int,
  span: Source.Span,
  expected: T.Type,
) -> Result[State.Out]
  definition = cx.enums.get(enum_name)
  if !definition.ok?
    if cx.aliases.has_key?(enum_name)
      underlying = try Types.alias_target_text(cx, st, enum_name)
      variant = "#{T.display_name(enum_name)}.#{variant_name}"
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-UNKNOWN-TYPE",
          "a type alias is not a declared enum",
          span,
          "#{variant} names #{underlying}.#{variant_name}; construct the underlying enum variant instead",
        ),
      )
    end

    return error(
      State.fail_maybe(
        cx,
        st,
        "CHECK-UNKNOWN-TYPE",
        "unknown enum \"#{enum_name}\"",
        span,
        unknown_enum_help(enum_name),
      ),
    )
  end

  found = definition.unwrap!
  payload = variant_payload(found, variant_name)
  if !payload.ok?
    return error(
      State.fail(
        cx,
        st,
        "CHECK-UNKNOWN-VARIANT",
        "enum \"#{T.display_name(enum_name)}\" has no variant \"#{variant_name}\"",
        span,
      ),
    )
  end

  count = args.size + named
  if count != payload.unwrap!.size
    variant = "#{T.display_name(enum_name)}.#{variant_name}"
    return error(
      State.fail(
        cx,
        st,
        "CHECK-ARITY",
        "variant #{variant} expects #{payload.unwrap!.size} argument(s), found #{count}",
        span,
      ),
    )
  end

  if named > 0
    return error(State.fail(cx, st, "CHECK-ENUM-POSITIONAL-ARGS", "enum variants use positional arguments", span))
  end

  substitutions = expected_substitutions("Enum", found.name, found.parameters, expected)
  inferred = try infer_arguments(cx, st, payload.unwrap!, args, substitutions)
  return finish_constructor(cx, inferred.st, found, variant_name, inferred.substitutions, span, expected)
end

## Checks Type(name: value, ...): a struct, or Enum.Variant(name: value) written as a construction, which a variant
## does not take.
export def check_construct(cx: State.Cx, st: State.St, node: Ast.Construct, expected: T.Type) -> Result[State.Out]
  parts = node.type_name.split(".")
  if parts.size == 2 and cx.enums.has_key?(parts[0])
    return check_enum_constructor(cx, st, parts[0], parts[1], [], node.args.size, node.span, expected)
  end

  return check_struct_construct(cx, st, node, expected)
end

## Checks target.with(name: value, ...): the target is a struct, every name is one of its fields, given once, with a
## value of the field's type. A struct that its module keeps private cannot be updated from another module
## (CHECK-IMPORT-NAME).
export def check_struct_update(cx: State.Cx, st: State.St, node: Ast.StructUpdate) -> Result[State.Out]
  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if !T.is?(target.type, "Struct")
    return error(
      State.fail_help(
        cx,
        target.st,
        "CHECK-UNKNOWN-METHOD",
        "#{T.to_text(target.type)} has no method \"with\"",
        node.span,
        "with copies a struct with some fields changed; the value before .with must be a struct",
      ),
    )
  end

  name = T.name(target.type)
  if !updatable?(cx, node.visible, name)
    return error(
      State.fail_help(
        cx,
        target.st,
        "CHECK-IMPORT-NAME",
        "\"#{T.display_name(name)}\" is private to its module, so a value of it cannot be updated here",
        node.span,
        "export the struct from its module, or add a function there that makes the change",
      ),
    )
  end

  fields = try check_named_fields(cx, target.st, name, Types.fields_of(cx, target.type), node.args, [], {})
  return ok(State.Out(st: fields.st, type: target.type))
end

## The field of that name in the list, or an error.
export def find_field(fields: List[Model.Named], name: String) -> Result[Model.Named]
  for field in fields
    if field.name == name
      return ok(field)
    end
  end

  return error("no such field")
end

# The text of the source between the start of an expression, including a piped receiver, and its end.
def extent_text(cx: State.Cx, node: Ast.Expr) -> String
  text = cx.texts.get(cx.file)
  if !text.ok?
    return ""
  end

  start = extent_start(node)
  stop = Ast.expr_span(node).stop.offset
  return text.unwrap!.slice(start, stop - start)
end

# The offset where an expression starts: a piped call starts where its receiver does, and so does a try of one.
def extent_start(node: Ast.Expr) -> Int
  case node
    Ast.Expr.Call(call) -> return call_start(call)
    Ast.Expr.Try(attempt) -> return try_start(attempt)
    _ -> return Ast.expr_span(node).start.offset
  end
end

def call_start(call: Ast.Call) -> Int
  if call.piped
    return extent_start(call.args[0])
  end

  return call.span.start.offset
end

def try_start(attempt: Ast.TryExpr) -> Int
  inner = extent_start(attempt.operand)
  if inner < attempt.span.start.offset
    return inner
  end

  return attempt.span.start.offset
end

def piped?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.Call(call) -> return call.piped
    Ast.Expr.Try(attempt) -> return piped?(attempt.operand)
    _ -> return false
  end
end

# CHECK-PIPE-METHOD: a builtin that has a method form (x |> String.upcase) is written as the method, x.upcase.
def check_pipe_method(cx: State.Cx, st: State.St, node: Ast.Call, entry: Model.Builtin) -> Result[Bool]
  selected = Builtins.form_for(entry, node.args.size)
  if !selected.ok? or selected.unwrap!.parameters.size == 0
    return ok(true)
  end

  kind = Names.receiver_kind(selected.unwrap!.parameters[0].type)
  if kind == ""
    return ok(true)
  end

  method = Names.pipe_method_name(cx, kind, entry.name)
  if method == ""
    return ok(true)
  end

  return error(
    State.fail_help(
      cx,
      st,
      "CHECK-PIPE-METHOD",
      "\"#{entry.name}\" has a method form for #{kind}, so it is not piped",
      node.span,
      pipe_help(cx, node, method),
    ),
  )
end

# The method form of a piped call: receiver.method(arguments) do ... end.
def pipe_help(cx: State.Cx, node: Ast.Call, method: String) -> String
  left = node.args[0]
  receiver = "(#{extent_text(cx, left)})"
  if simple_receiver?(left) and !piped?(left)
    receiver = extent_text(cx, left)
  end

  plain: List[String] = []
  block = false
  index = 1
  while index < node.args.size
    case node.args[index]
      Ast.Expr.BlockLit(found) -> block = true
      _ -> plain = plain.push(extent_text(cx, node.args[index]))
    end

    index += 1
  end

  text = "#{receiver}.#{method}"
  if plain.size > 0
    text = "#{text}(#{plain.join(", ")})"
  end

  if block
    text = "#{text} do ... end"
  end

  return text
end

def simple_receiver?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.Name(found) -> return true
    Ast.Expr.Literal(found) -> return true
    Ast.Expr.Call(found) -> return true
    Ast.Expr.MethodCall(found) -> return true
    Ast.Expr.FieldAccess(found) -> return true
    Ast.Expr.Index(found) -> return true
    _ -> return false
  end
end

# A function of the program: the arguments against the parameter types. A generic function infers its type arguments
# first (check_generic_call).
def check_plain_call(cx: State.Cx, st: State.St, node: Ast.Call, expected: T.Type) -> Result[State.Out]
  entry = cx.functions.get(node.name)
  if !entry.ok?
    return error(
      State.fail_maybe(
        cx,
        st,
        "CHECK-UNKNOWN-NAME",
        "unknown function \"#{T.display_name(node.name)}\"",
        node.span,
        unknown_function_help(cx, node.name),
      ),
    )
  end

  signature = entry.unwrap!
  shape = signature.shape
  count = node.args.size
  if count < shape.required or count > shape.total
    return error(arity_failure(cx, st, node, signature))
  end

  if signature.type_parameters.size > 0
    return check_generic_call(cx, st, node, signature, expected)
  end

  current = st
  index = 0
  while index < count
    out = try State.expr(cx, current, node.args[index], signature.params[Defaults.param_of(shape, count, index)])
    current = out.st
    index += 1
  end

  return ok(State.Out(st: current, type: signature.result))
end

# A call of a generic function. Each call has its own type variables: the signature is a template, and the arguments
# bind its variables to types (which may hold the variables of the caller, and are never read again as template). The
# order is:
#   1. the arguments that have a type of their own, from left to right, each against its parameter type as far as the
#      variables are known;
#   2. the expected type of the call, matched with the result type, for the variables still open;
#   3. the arguments that need an expected type ([], {}, error(...), Option.None, &f of a generic function ...),
#      against their parameter type, and they bind nothing;
#   4. the block, which may bind the variables its annotated parameters and its result show.
# A step 3 argument whose parameter type is still open waits for the block, and is checked after it.
def check_generic_call(
  cx: State.Cx,
  st: State.St,
  node: Ast.Call,
  signature: State.Signature,
  expected: T.Type,
) -> Result[State.Out]
  count = node.args.size
  shape = signature.shape
  current = st
  found: Map[String, T.Type] = {}
  waiting: List[Int] = []
  block = -1
  index = 0
  while index < count
    template = signature.params[Defaults.param_of(shape, count, index)]
    arg = node.args[index]
    if index == count - 1 and block_literal?(arg) and T.is?(template, "Fn")
      block = index
    elsif needs_expected?(cx, arg)
      waiting = waiting.push(index)
    else
      out = try State.expr(cx, current, arg, known_part(template, found))
      current = out.st
      found = try Types.unify(cx, current, template, out.type, found, Ast.expr_span(arg))
    end

    index += 1
  end

  found = Types.learn(signature.result, expected, found)
  later: List[Int] = []
  for at in waiting
    template = signature.params[Defaults.param_of(shape, count, at)]
    if Types.open_variables?(template, found)
      later = later.push(at)
    else
      current = try check_closed_argument(cx, current, node.args[at], template, found)
    end
  end

  if block >= 0
    template = signature.params[Defaults.param_of(shape, count, block)]
    after = try check_generic_block(cx, current, node.args[block], template, found)
    current = after.st
    found = after.substitutions
  end

  for at in later
    template = signature.params[Defaults.param_of(shape, count, at)]
    if Types.open_variables?(template, found)
      return error(uninferred_failure(cx, current, node, signature, found))
    end

    current = try check_closed_argument(cx, current, node.args[at], template, found)
  end

  unresolved = signature.type_parameters.filter do |name: String| !found.has_key?(name) end
  if unresolved.size > 0
    return error(uninferred_failure(cx, current, node, signature, found))
  end

  try check_void_arguments(cx, current, node, signature, found)
  return ok(State.Out(st: current, type: Types.substitute(signature.result, found)))
end

# The parameter type with the variables found so far put in, or Unknown while one is open: an argument is then checked
# for a type of its own.
def known_part(template: T.Type, found: Map[String, T.Type]) -> T.Type
  if Types.open_variables?(template, found)
    return T.Type.Unknown
  end

  return Types.substitute(template, found)
end

def block_literal?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.BlockLit(found) -> return true
    _ -> return false
  end
end

# An argument that has no type of its own, so it waits for the others: an empty list or map, error(...), Set.new of an
# empty list, a variant of a generic enum with no payload, a list or map literal that holds one of those, and the
# reference of a generic function.
def needs_expected?(cx: State.Cx, node: Ast.Expr) -> Bool
  case node
    Ast.Expr.ListLit(list) ->
      return list.elements.size == 0 or list.elements.any? do |item: Ast.Expr| needs_expected?(cx, item) end
    Ast.Expr.MapLit(map) ->
      return map.entries.size == 0 or map.entries.any? do |entry: Ast.MapEntry| needs_expected?(cx, entry.value) end
    Ast.Expr.Call(call) ->
      set_of_empty = call.name == "Set.new" and call.args.size == 1 and needs_expected?(cx, call.args[0])
      return call.name == "error" or set_of_empty
    Ast.Expr.EnumConstructor(variant) ->
      definition = cx.enums.get(variant.enum_name)
      return variant.args.size == 0 and definition.ok? and definition.unwrap!.parameters.size > 0
    Ast.Expr.FunctionRef(ref) ->
      signature = cx.functions.get(ref.name)
      return signature.ok? and signature.unwrap!.type_parameters.size > 0
    _ -> return false
  end
end

# An argument checked against its parameter type, which has no open variable. It binds nothing.
def check_closed_argument(
  cx: State.Cx,
  st: State.St,
  arg: Ast.Expr,
  template: T.Type,
  found: Map[String, T.Type],
) -> Result[State.St]
  out = try State.expr(cx, st, arg, Types.substitute(template, found))
  try Types.unify(cx, out.st, template, out.type, found, Ast.expr_span(arg))
  return ok(out.st)
end

# The block of a call, against the Fn parameter type. Its parameter types are the ones known; one still open must be
# annotated in the block (CHECK-BLOCK-TYPE otherwise), and an annotation binds it. The block's result binds what the Fn
# result leaves open: a Result type is asked for as such, so that ok(...) and error(...) are read as the block's value.
def check_generic_block(
  cx: State.Cx,
  st: State.St,
  node: Ast.Expr,
  template: T.Type,
  found: Map[String, T.Type],
) -> Result[Inferred]
  params = T.params(template).map do |param: T.Type| known_part(param, found) end
  result = known_part(T.result(template), found)
  if T.unknown?(result) and T.is?(T.result(template), "Result")
    result = T.Type.Result(T.Type.Unknown)
  end

  case node
    Ast.Expr.BlockLit(block) ->
      out = try Stmt.check_block_in(cx, st, block, Ast.Optional.Present(params), result, Ast.Optional.Absent, false)
      learned = try Types.unify(cx, out.st, template, out.type, found, block.span)
      return ok(Inferred(st: out.st, substitutions: learned))
    _ -> return error(State.fail(cx, st, "CHECK-INTERNAL", "a block argument is not a block", Ast.expr_span(node)))
  end
end

# CHECK-ENUM-TYPE-INFERENCE at the call, for the type parameters that the arguments and the expected type leave open.
def uninferred_failure(
  cx: State.Cx,
  st: State.St,
  node: Ast.Call,
  signature: State.Signature,
  found: Map[String, T.Type],
) -> String
  unset = signature.type_parameters.filter do |name: String| !found.has_key?(name) end
  if unset.size == 0
    unset = signature.type_parameters
  end

  return State.fail_help(
    cx,
    st,
    "CHECK-ENUM-TYPE-INFERENCE",
    "cannot infer type parameter(s) #{unset.join(", ")} of #{T.display_name(node.name)}",
    node.span,
    "give the call a type where it is used, such as a variable with a type annotation, or an argument that shows it",
  )
end

# CHECK-VOID-TYPE at the call when a type argument is Void where a value is needed: in a parameter, a field or a list
# item. A result, the last type of an Fn and the item of a Result or a Task may be Void.
def check_void_arguments(
  cx: State.Cx,
  st: State.St,
  node: Ast.Call,
  signature: State.Signature,
  found: Map[String, T.Type],
) -> Result[Bool]
  misplaced = Types.misplaced_void?(Types.substitute(signature.result, found), true)
  for param in signature.params
    misplaced = misplaced or Types.misplaced_void?(Types.substitute(param, found), false)
  end

  if misplaced
    return error(
      State.fail(
        cx,
        st,
        "CHECK-VOID-TYPE",
        "a type argument of #{T.display_name(node.name)} is Void where a value is needed",
        node.span,
      ),
    )
  end

  return ok(true)
end

# A function with defaults says the range of arguments it takes.
def arity_failure(cx: State.Cx, st: State.St, node: Ast.Call, signature: State.Signature) -> String
  name = T.display_name(node.name)
  shape = signature.shape
  wanted = "#{shape.total} argument(s)"
  if Defaults.has_defaults?(shape)
    wanted = "#{shape.required} to #{shape.total} arguments"
  end

  message = "\"#{name}\" expects #{wanted}, found #{node.args.size}"
  callee = "#{name}(#{T.list_text(signature.params)}) -> #{T.to_text(signature.result)}"
  return State.fail_callee(cx, st, "CHECK-ARITY", message, node.span, callee)
end

# The help of an unknown function: a name of another language, a module that needs an import, or a close name.
def unknown_function_help(cx: State.Cx, name: String) -> String
  help = Help.foreign(cx.help, name)
  if help != ""
    return help
  elsif name.starts_with?("Agent.")
    return (
      "return values from tasks and combine them with reduce, " +
      "or keep the state in one task that receives on a Channel"
    )
  elsif name.starts_with?("BDD.")
    return "import BDD from \"std/bdd\""
  elsif name.starts_with?("HTTP.")
    return "import HTTP from \"std/http\""
  end

  return Help.near(name, cx.functions.keys, PUBLIC_NAMES)
end

def unknown_enum_help(name: String) -> String
  if name == "Result"
    return "Result has only Ok and Err: Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")"
  end

  return ""
end

# The payload types of a variant of the enum, or an error when it has no such variant.
def variant_payload(definition: Model.EnumDef, name: String) -> Result[List[T.Type]]
  for variant in definition.variants
    if variant.name == name
      return ok(variant.payload)
    end
  end

  return error("no such variant")
end

# The type arguments the context already gives: an expected type of the same kind ("Enum" or "Struct") and name, with
# the same number of arguments as the type has parameters.
def expected_substitutions(
  kind: String,
  name: String,
  parameters: List[String],
  expected: T.Type,
) -> Map[String, T.Type]
  args = T.args(expected)
  if T.is?(expected, kind) and T.name(expected) == name and args.size == parameters.size
    return Types.bindings(parameters, args)
  end

  return {}
end

# Each argument against its payload type with the type variables filled in as far as they are known; an empty
# collection cannot say what a variable is.
def infer_arguments(
  cx: State.Cx,
  st: State.St,
  payload: List[T.Type],
  args: List[Ast.Expr],
  substitutions: Map[String, T.Type],
) -> Result[Inferred]
  current = st
  found = substitutions
  index = 0
  while index < payload.size
    template = payload[index]
    context = Types.substitute(template, found)
    unset = Types.open_variables?(template, found)
    if unset and empty_collection?(args[index])
      return error(
        State.fail(
          cx,
          current,
          "CHECK-ENUM-TYPE-INFERENCE",
          "cannot infer enum type arguments from an empty collection payload",
          Ast.expr_span(args[index]),
        ),
      )
    end

    wanted = context
    if unset
      wanted = T.Type.Unknown
    end

    out = try State.expr(cx, current, args[index], wanted)
    current = out.st
    found = try Types.unify(cx, current, template, out.type, found, Ast.expr_span(args[index]))
    index += 1
  end

  return ok(Inferred(st: current, substitutions: found))
end

def empty_collection?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.ListLit(list) -> return list.elements.size == 0
    Ast.Expr.MapLit(map) -> return map.entries.size == 0
    _ -> return false
  end
end

# The enum type with its arguments, once every type parameter has been found.
def finish_constructor(
  cx: State.Cx,
  st: State.St,
  definition: Model.EnumDef,
  variant_name: String,
  substitutions: Map[String, T.Type],
  span: Source.Span,
  expected: T.Type,
) -> Result[State.Out]
  unresolved = definition.parameters.filter do |parameter: String| !substitutions.has_key?(parameter) end
  if unresolved.size > 0
    variant = "#{T.display_name(definition.name)}.#{variant_name}"
    return error(
      State.fail(
        cx,
        st,
        "CHECK-ENUM-TYPE-INFERENCE",
        "cannot infer enum type parameter(s) #{unresolved.join(", ")} for #{variant}",
        span,
      ),
    )
  end

  args = definition.parameters.map do |parameter: String| substitutions[parameter] end
  type = try State.ensure(cx, st, T.Type.Enum(definition.name, args), expected, span)
  return ok(State.Out(st: st, type: type))
end

# Type(name: value, ...) for a struct. A generic struct takes its type arguments from the field values, left to right
# as they are written, and from the expected type.
def check_struct_construct(cx: State.Cx, st: State.St, node: Ast.Construct, expected: T.Type) -> Result[State.Out]
  name = node.type_name
  if cx.aliases.has_key?(name)
    target = try Types.alias_target_text(cx, st, name)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNKNOWN-TYPE",
        "a type alias is not a declared struct",
        node.span,
        "#{T.display_name(name)} names #{target}; construct the underlying type instead",
      ),
    )
  end

  fields = cx.structs.get(name)
  if !fields.ok?
    return error(
      State.fail_maybe(
        cx,
        st,
        "CHECK-UNKNOWN-TYPE",
        "\"#{T.display_name(name)}\" is not a declared struct",
        node.span,
        Help.near(name, cx.structs.keys, []),
      ),
    )
  end

  parameters = cx.struct_params.get(name, [])
  known = expected_substitutions("Struct", name, parameters, expected)
  checked = try check_named_fields(cx, st, name, fields.unwrap!, node.args, parameters, known)
  # A field with a default may be left out: the lowering fills it in at this construction.
  none: Set[String] = Set.new([])
  defaulted = cx.field_defaults.get(name, none)
  for field in fields.unwrap!
    if !checked.seen.include?(field.name) and !defaulted.include?(field.name)
      return error(
        State.fail_help(
          cx,
          checked.st,
          "CHECK-MISSING-FIELD",
          "constructor \"#{T.display_name(name)}\" is missing field \"#{field.name}\"",
          node.span,
          "add \"#{field.name}: ...\" with a value of type #{T.to_text(field.type)}",
        ),
      )
    end
  end

  if parameters.size == 0
    return ok(State.Out(st: checked.st, type: T.Type.Struct(name, [])))
  end

  return finish_struct(cx, checked, name, parameters, node.span, expected)
end

# The generic struct type with its arguments, once every type parameter has been found.
def finish_struct(
  cx: State.Cx,
  checked: Fields,
  name: String,
  parameters: List[String],
  span: Source.Span,
  expected: T.Type,
) -> Result[State.Out]
  unresolved = parameters.filter do |parameter: String| !checked.substitutions.has_key?(parameter) end
  if unresolved.size > 0
    return error(
      State.fail_help(
        cx,
        checked.st,
        "CHECK-ENUM-TYPE-INFERENCE",
        "cannot infer type parameter(s) #{unresolved.join(", ")} of struct #{T.display_name(name)}",
        span,
        "give the struct a type where it is used, such as a variable with a type annotation",
      ),
    )
  end

  args = parameters.map do |parameter: String| checked.substitutions[parameter] end
  type = try State.ensure(cx, checked.st, T.Type.Struct(name, args), expected, span)
  return ok(State.Out(st: checked.st, type: type))
end

# The `name: value` pairs of a construction or an update: each name is a field of the struct, given once, with a value
# of the field's type. The values are checked in source order, which is also the order they run in. For a generic
# struct, parameters lists its type parameters and known the arguments that the expected type gives: each value is
# checked against the field type as far as it is known, and a value whose type has a type parameter in it binds that
# parameter. An empty collection cannot bind one (CHECK-ENUM-TYPE-INFERENCE), as in a variant.
def check_named_fields(
  cx: State.Cx,
  st: State.St,
  name: String,
  fields: List[Model.Named],
  args: List[Ast.NamedArg],
  parameters: List[String],
  known: Map[String, T.Type],
) -> Result[Fields]
  current = st
  found = known
  seen: Set[String] = Set.new([])
  for arg in args
    field = find_field(fields, arg.name)
    if !field.ok?
      return error(
        State.fail_help(
          cx,
          current,
          "CHECK-UNKNOWN-FIELD",
          "\"#{T.display_name(name)}\" has no field \"#{arg.name}\"",
          arg.span,
          Help.field_help(arg.name, fields),
        ),
      )
    end

    if seen.include?(arg.name)
      return error(
        State.fail(cx, current, "CHECK-DUPLICATE-FIELD", "field \"#{arg.name}\" is given twice", arg.span),
      )
    end

    seen = seen.add(arg.name)
    template = field.unwrap!.type
    wanted = template
    if parameters.size > 0
      wanted = Types.substitute(template, found)
      unset = Types.open_variables?(template, found)
      if unset and empty_collection?(arg.value)
        return error(empty_field_failure(cx, current, name, Ast.expr_span(arg.value)))
      end

      if unset
        wanted = T.Type.Unknown
      end
    end

    out = try State.expr(cx, current, arg.value, wanted)
    current = out.st
    if parameters.size > 0
      found = try Types.unify(cx, current, template, out.type, found, Ast.expr_span(arg.value))
    end
  end

  return ok(Fields(st: current, seen: seen, substitutions: found))
end

def empty_field_failure(cx: State.Cx, st: State.St, name: String, span: Source.Span) -> String
  return State.fail_help(
    cx,
    st,
    "CHECK-ENUM-TYPE-INFERENCE",
    "cannot infer the type arguments of struct #{T.display_name(name)} from an empty collection",
    span,
    "give the struct a type where it is used, such as a variable with a type annotation",
  )
end

# A builtin record can always be updated; a struct of the program only when the file may build it. Absent: the program
# is not linked, every struct is visible.
def updatable?(cx: State.Cx, visible: Ast.Optional[List[String]], name: String) -> Bool
  case visible
    Ast.Optional.Present(names) ->
      return RECORDS.has_key?(name) or names.any? do |item: String| item == name end
    Ast.Optional.Absent -> return true
  end
end
