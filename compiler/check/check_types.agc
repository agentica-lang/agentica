## Types in the checker: reading a type written in the source (resolve_type), the questions the rules ask of a type
## (can it be printed, encoded to JSON, decoded from JSON), and the type variables of generic enums (substitute,
## unify). These are the helpers that do not depend on the walk of the tree.

import {ENUMS, OPAQUE_TYPES} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Help from "check_help"
import State from "check_state"

type ResolvedType = Types.Type

type TypeRef = Ast.TypeRef

struct Expansion
  ref: TypeRef
  remaining: Int
end

## The type a type written in the source stands for. completion says Void is allowed here (a result type, or the item
## of a Result or Task). The first problem is CHECK-VOID-TYPE, CHECK-MAP-KEY-TYPE, CHECK-SET-ELEMENT-TYPE or
## CHECK-UNKNOWN-TYPE.
export def resolve_type(cx: State.Cx, st: State.St, ref: TypeRef, completion: Bool) -> Result[ResolvedType]
  if !contains_alias?(cx, ref)
    return resolve_expanded(cx, st, ref, completion)
  end

  expanded = try expand_alias(cx, st, ref, [], State.nesting_limit(), ref.span)
  return resolve_expanded(cx, st, expanded.ref, completion)
end

## The types of several type references, in order.
export def resolve_all(cx: State.Cx, st: State.St, refs: List[TypeRef]) -> Result[List[ResolvedType]]
  out: List[ResolvedType] = []
  for ref in refs
    out = out.push(try resolve_type(cx, st, ref, false))
  end

  return ok(out)
end

## The context that checks the target of a type alias: the alias's type parameters are in scope as type variables. A
## parameter may be a Map key or a Set element here (as in the files of the prelude): it stands for any type, so the
## key rule is judged where the alias is used, on the expanded type.
export def alias_scope(cx: State.Cx, decl: Ast.TypeAliasDecl) -> State.Cx
  if decl.type_parameters.size == 0
    return cx
  end

  return cx.with(type_params: decl.type_parameters, prelude: true)
end

## The type an alias stands for as text; a generic alias prints its parameters (List[List[T]]).
export def alias_target_text(cx: State.Cx, st: State.St, name: String) -> Result[String]
  decl = cx.aliases[name]
  target = try resolve_type(alias_scope(cx, decl), st, decl.target, true)
  return ok(Types.to_text(target))
end

## True for Int and String, the types of a Map key or a Set element.
export def key_type?(type: ResolvedType) -> Bool
  return Types.is?(type, "Int") or Types.is?(type, "String")
end

## True when the type may be a Map key or a Set element where cx checks: Int and String, and in the files of the
## prelude a type variable too (the checker has checked the types it stands for, check_prelude.agc).
export def key_here?(cx: State.Cx, type: ResolvedType) -> Bool
  return key_type?(type) or (cx.prelude and Types.is?(type, "Var"))
end

## True for Int and Float.
export def numeric?(type: ResolvedType) -> Bool
  return Types.is?(type, "Int") or Types.is?(type, "Float")
end

## True for Int, Float, Bool, String and Nil, the types that == compares.
export def primitive?(type: ResolvedType) -> Bool
  return numeric?(type) or Types.is?(type, "Bool") or Types.is?(type, "String") or Types.is?(type, "Nil")
end

## True for JsonField[T], the builtin enum of an optional and nullable JSON field.
export def json_field?(type: ResolvedType) -> Bool
  return Types.is?(type, "Enum") and Types.name(type) == "JsonField" and Types.args(type).size == 1
end

## Where the type has a JsonField that a JSON builtin does not allow, or "" when it has none: JsonField may only be the
## direct type of a struct field. direct says the type is a struct field's own type, kind names its place when it is
## not ("list item", "map value", "nested JsonField", "encode argument") and owner the struct field it sits in
## ("Wrapper.items", "" outside a struct). seen holds the structs already walked ("Struct:name"), so a recursive type
## ends. Runs before the decodable and encodable tests.
export def json_field_place(
  cx: State.Cx, type: ResolvedType, direct: Bool, kind: String, owner: String, seen: List[String]
) -> String
  if json_field?(type)
    if !direct
      if owner == ""
        return kind
      end

      return "#{kind} in #{owner}"
    end

    return json_field_place(cx, Types.args(type)[0], false, "nested JsonField", owner, seen)
  elsif Types.is?(type, "List")
    return json_field_place(cx, Types.item(type), false, "list item", owner, seen)
  elsif Types.is?(type, "Map")
    return json_field_place(cx, Types.value(type), false, "map value", owner, seen)
  elsif Types.is?(type, "Struct") and cx.structs.has_key?(Types.name(type))
    key = "Struct:#{Types.name(type)}"
    if seen.any? do |item: String| item == key end
      return ""
    end

    inner = seen.push(key)
    place = Types.display_name(Types.name(type))
    for field in cx.structs[Types.name(type)]
      found = json_field_place(cx, field.type, true, "struct field", "#{place}.#{field.name}", inner)
      if found != ""
        return found
      end
    end
  end

  return ""
end

## True when JSON.encode can write a value of the type: primitives, Json, lists, maps with String keys, structs of
## those, and JsonField of an encodable type other than Nil.
export def encodable?(cx: State.Cx, type: ResolvedType, seen: List[String]) -> Bool
  if primitive?(type) or Types.is?(type, "Json")
    return true
  elsif json_field?(type)
    return !Types.is?(Types.args(type)[0], "Nil") and encodable?(cx, Types.args(type)[0], seen)
  elsif Types.is?(type, "List")
    return encodable?(cx, Types.item(type), seen)
  elsif Types.is?(type, "Map")
    return Types.is?(Types.key(type), "String") and encodable?(cx, Types.value(type), seen)
  elsif Types.is?(type, "Struct")
    return struct_all?(cx, Types.name(type), seen, 0)
  end

  return false
end

## True when JSON.decode can read a value of the type: Int, Float, Bool, String, lists, maps with String keys, structs
## of those, and JsonField of a decodable type (Nil is not one).
export def decodable?(cx: State.Cx, type: ResolvedType, seen: List[String]) -> Bool
  if Types.is?(type, "Int") or Types.is?(type, "Float") or Types.is?(type, "Bool") or Types.is?(type, "String")
    return true
  elsif json_field?(type)
    return decodable?(cx, Types.args(type)[0], seen)
  elsif Types.is?(type, "List")
    return decodable?(cx, Types.item(type), seen)
  elsif Types.is?(type, "Map")
    return Types.is?(Types.key(type), "String") and decodable?(cx, Types.value(type), seen)
  elsif Types.is?(type, "Struct")
    return struct_all?(cx, Types.name(type), seen, 1)
  end

  return false
end

## True when the type may be the value of an ATS: a data type (data?, a deep walk that rejects Fn, Task, Channel, every
## handle and ATS itself, so no table holds a table) that is not Nil and has no type variable. A variable is allowed
## only where it is checked later: in the target of a generic alias (cx.prelude), whose uses are checked expanded. A
## generic enum checks its arguments only with data?, which accepts a variable, so a payload ATS[String, T] is refused.
export def ats_value?(cx: State.Cx, type: ResolvedType) -> Bool
  if Types.is?(type, "Nil") or !data?(cx, type, [])
    return false
  end

  return cx.prelude or !has_variables?(type)
end

## CHECK-ATS-VALUE for the value type of an ATS that ats_value? refuses, at span.
export def ats_value_failure(cx: State.Cx, st: State.St, type: ResolvedType, span: Source.Span) -> String
  return State.fail_help(
    cx,
    st,
    "CHECK-ATS-VALUE",
    "an ATS value must be a data type with no Fn, Task, handle or ATS inside, found #{Types.to_text(type)}",
    span,
    "keep plain data in the table (numbers, strings, lists, maps, structs and enums of those)",
  )
end

## True for a type that has to_s: the data types. Numbers, Bool, String, nil, Json, ranges, type variables, and lists,
## maps, sets, Results, structs and enums of those. seen holds the structs and enums already being looked at
## ("Struct:name"), so a recursive type ends.
export def data?(cx: State.Cx, type: ResolvedType, seen: List[String]) -> Bool
  if primitive?(type) or Types.is?(type, "Json") or Types.is?(type, "Range") or Types.is?(type, "Var")
    return true
  elsif Types.is?(type, "List")
    return data?(cx, Types.item(type), seen)
  elsif Types.is?(type, "Map")
    return data?(cx, Types.key(type), seen) and data?(cx, Types.value(type), seen)
  elsif Types.is?(type, "Set")
    return true
  elsif Types.is?(type, "Result")
    return Types.is?(Types.item(type), "Void") or data?(cx, Types.item(type), seen)
  elsif Types.is?(type, "Struct") or Types.is?(type, "Enum")
    return nominal_data?(cx, type, seen)
  end

  return false
end

## True when the type has a type variable inside.
export def has_variables?(type: ResolvedType) -> Bool
  case type
    Types.Type.Var(name) -> return true
    Types.Type.Result(item) -> return has_variables?(item)
    Types.Type.Task(item) -> return has_variables?(item)
    Types.Type.Channel(item) -> return has_variables?(item)
    Types.Type.Lazy(item) -> return has_variables?(item)
    Types.Type.List(item) -> return has_variables?(item)
    Types.Type.Set(item) -> return has_variables?(item)
    Types.Type.Map(key, value) -> return has_variables?(key) or has_variables?(value)
    Types.Type.ATS(key, value) -> return has_variables?(key) or has_variables?(value)
    Types.Type.Fn(params, result) ->
      return params.any? do |param: ResolvedType| has_variables?(param) end or has_variables?(result)
    Types.Type.Enum(name, args) -> return args.any? do |arg: ResolvedType| has_variables?(arg) end
    _ -> return false
  end
end

## The type with each type variable that has a substitution replaced.
export def substitute(type: ResolvedType, substitutions: Map[String, ResolvedType]) -> ResolvedType
  case type
    Types.Type.Var(name) -> return substitution(type, name, substitutions)
    Types.Type.Result(item) -> return Types.Type.Result(substitute(item, substitutions))
    Types.Type.Task(item) -> return Types.Type.Task(substitute(item, substitutions))
    Types.Type.Channel(item) -> return Types.Type.Channel(substitute(item, substitutions))
    Types.Type.Lazy(item) -> return Types.Type.Lazy(substitute(item, substitutions))
    Types.Type.List(item) -> return Types.Type.List(substitute(item, substitutions))
    Types.Type.Set(item) -> return Types.Type.Set(substitute(item, substitutions))
    Types.Type.Map(key, value) -> return Types.Type.Map(
      substitute(key, substitutions),
      substitute(value, substitutions),
    )
    Types.Type.ATS(key, value) -> return Types.Type.ATS(
      substitute(key, substitutions),
      substitute(value, substitutions),
    )
    Types.Type.Fn(params, result) -> return Types.Type.Fn(
      substitute_all(params, substitutions),
      substitute(result, substitutions),
    )
    Types.Type.Enum(name, args) -> return Types.Type.Enum(name, substitute_all(args, substitutions))
    _ -> return type
  end
end

## substitute for each type of a list.
export def substitute_all(types: List[ResolvedType], substitutions: Map[String, ResolvedType]) -> List[ResolvedType]
  return types.map do |type: ResolvedType| substitute(type, substitutions) end
end

## Matches the actual type against a template that may have type variables, and returns the substitutions with what the
## match learned. A variable already set must match again; a template with no variable must equal the actual type, else
## CHECK-TYPE-MISMATCH.
export def unify(
  cx: State.Cx,
  st: State.St,
  template: ResolvedType,
  actual: ResolvedType,
  substitutions: Map[String, ResolvedType],
  span: Source.Span,
) -> Result[Map[String, ResolvedType]]
  if Types.is?(template, "Var")
    previous = substitutions.get(Types.name(template))
    if previous.ok?
      try State.ensure(cx, st, actual, previous.unwrap!, span)
      return ok(substitutions)
    end

    return ok(substitutions.put(Types.name(template), actual))
  end

  if composite?(template) and Types.tag(template) == Types.tag(actual)
    return unify_inside(cx, st, template, actual, substitutions, span)
  end

  try State.ensure(cx, st, actual, template, span)
  return ok(substitutions)
end

def contains_alias?(cx: State.Cx, ref: TypeRef) -> Bool
  if !cx.type_params.any? do |item: String| item == ref.name end and cx.aliases.has_key?(ref.name)
    return true
  end

  return ref.args.any? do |arg: TypeRef| contains_alias?(cx, arg) end
end

def expand_alias(
  cx: State.Cx,
  st: State.St,
  ref: TypeRef,
  seen: List[String],
  remaining: Int,
  limit_span: Source.Span,
) -> Result[Expansion]
  if remaining <= 0
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-TOO-DEEP",
        "expanded type contains more than #{State.nesting_limit()} type references",
        limit_span,
        "simplify the type or split its aliases",
      ),
    )
  end

  left = remaining - 1
  name = ref.name
  parameter = cx.type_params.any? do |item: String| item == name end
  if !parameter and cx.aliases.has_key?(name)
    decl = cx.aliases[name]
    if ref.args.size != decl.type_parameters.size
      return error(State.fail(cx, st, "CHECK-UNKNOWN-TYPE", alias_arity_text(name, decl, ref), ref.span))
    end

    if seen.any? do |entry: String| entry == name end
      cycle = cycle_text(seen, name)
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-TYPE-ALIAS-CYCLE",
          "type alias has a cycle",
          ref.span,
          "the cycle is #{cycle}",
        ),
      )
    end

    if seen.size >= State.nesting_limit()
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-TOO-DEEP",
          "nesting is deeper than #{State.nesting_limit()} levels",
          ref.span,
          "split the type aliases into a shallower chain",
        ),
      )
    end

    return expand_use(cx, st, decl, ref, seen, left, limit_span)
  end

  args: List[TypeRef] = []
  for arg in ref.args
    expanded = try expand_alias(cx, st, arg, seen, left, limit_span)
    args = args.push(expanded.ref)
    left = expanded.remaining
  end

  return ok(Expansion(ref: ref.with(args: args), remaining: left))
end

# One use of a declared alias: the arguments first, in the scope of the use, so an alias in an argument is not taken
# for a cycle of this one (Box[Box[Int]]). Then the target, read with only the parameters of the alias in scope, so a
# name in it is never taken for a type parameter of the use, and given the span of the use. The arguments go in last,
# in one pass, with the spans they have. seen holds the aliases being expanded around this use.
def expand_use(
  cx: State.Cx,
  st: State.St,
  decl: Ast.TypeAliasDecl,
  ref: TypeRef,
  seen: List[String],
  remaining: Int,
  limit_span: Source.Span,
) -> Result[Expansion]
  budget_span = limit_span
  if seen.size == 0
    budget_span = ref.span
  end

  left = remaining
  args: List[TypeRef] = []
  argument_refs = 0
  for arg in ref.args
    inner = try expand_alias(cx, st, arg, seen, left, limit_span)
    args = args.push(inner.ref)
    argument_refs += ref_count(inner.ref)
    left = inner.remaining
  end

  inside = cx.with(type_params: decl.type_parameters)
  target = try expand_alias(inside, st, decl.target, seen.push(ref.name), left, budget_span)
  shape = relocate(target.ref, ref.span)
  try check_capture(cx, st, shape, decl.type_parameters, ref.span)
  try check_unused_arguments(cx, st, shape, decl.type_parameters, args)
  result = replace_parameters(shape, decl.type_parameters, args)
  # An argument used twice is copied, and each copy counts against the limit like a reference written there.
  left = target.remaining - (ref_count(result) - ref_count(shape) - argument_refs)
  if left < 0
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-TOO-DEEP",
        "expanded type contains more than #{State.nesting_limit()} type references",
        limit_span,
        "simplify the type or split its aliases",
      ),
    )
  end

  return ok(Expansion(ref: result, remaining: left))
end

def alias_arity_text(name: String, decl: Ast.TypeAliasDecl, ref: TypeRef) -> String
  shown = Types.display_name(name)
  if decl.type_parameters.size == 0
    return "type alias #{shown} takes no type arguments"
  end

  return "type alias #{shown} #{expects_text(decl.type_parameters.size, ref.args.size)}"
end

# The tail of the arity message of a generic alias or enum.
def expects_text(expected: Int, found: Int) -> String
  return "expects #{expected} type argument(s), found #{found}"
end

# The target of a generic alias with each parameter replaced by its argument. One pass: an argument is not searched
# again, so a parameter name inside an argument (the T of the use) stays.
def replace_parameters(ref: TypeRef, parameters: List[String], args: List[TypeRef]) -> TypeRef
  if ref.args.size == 0
    index = 0
    while index < parameters.size
      if parameters[index] == ref.name
        return args[index]
      end

      index += 1
    end

    return ref
  end

  inner = ref.args.map do |arg: TypeRef| replace_parameters(arg, parameters, args) end
  return ref.with(args: inner)
end

# CHECK-UNKNOWN-TYPE when the expanded target names a type that a type parameter of the use hides. Reading the name as
# the parameter would give the alias another meaning than the one it has where it is declared.
def check_capture(
  cx: State.Cx,
  st: State.St,
  target: TypeRef,
  parameters: List[String],
  span: Source.Span,
) -> Result[Bool]
  hidden = (
    target.args.size == 0 and
    cx.type_params.any? do |item: String| item == target.name end and
    !parameters.any? do |item: String| item == target.name end
  )
  if hidden
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNKNOWN-TYPE",
        "type parameter \"#{Types.display_name(target.name)}\" hides the type of that name which this alias refers to",
        span,
        "rename the type parameter",
      ),
    )
  end

  for arg in target.args
    try check_capture(cx, st, arg, parameters, span)
  end

  return ok(true)
end

# A parameter that the target does not use drops its argument in the substitution; the argument still has to be a type
# (Unused[Nope], Unused[Map[List[Int], Int]]). Void stays legal, as in Res[Void].
def check_unused_arguments(
  cx: State.Cx,
  st: State.St,
  target: TypeRef,
  parameters: List[String],
  args: List[TypeRef],
) -> Result[Bool]
  index = 0
  while index < parameters.size
    if !uses_name?(target, parameters[index])
      try resolve_expanded(cx, st, args[index], true)
    end

    index += 1
  end

  return ok(true)
end

def uses_name?(ref: TypeRef, name: String) -> Bool
  if ref.args.size == 0
    return ref.name == name
  end

  return ref.args.any? do |arg: TypeRef| uses_name?(arg, name) end
end

# The number of type references written in the type: the unit of the expansion limit.
def ref_count(ref: TypeRef) -> Int
  total = 1
  for arg in ref.args
    total += ref_count(arg)
  end

  return total
end

def relocate(ref: TypeRef, span: Source.Span) -> TypeRef
  args = ref.args.map do |arg: TypeRef| relocate(arg, span) end
  return ref.with(args: args, span: span)
end

def cycle_text(seen: List[String], repeated: String) -> String
  names: List[String] = []
  copying = false
  for name in seen
    if copying or name == repeated
      copying = true
      names = names.push(name)
    end
  end

  names = names.push(repeated).map do |name: String| Types.display_name(name) end
  return names.join(" -> ")
end

def resolve_expanded(cx: State.Cx, st: State.St, ref: TypeRef, completion: Bool) -> Result[ResolvedType]
  name = ref.name
  args = ref.args
  if args.size == 0
    return resolve_plain(cx, st, ref, completion)
  end

  if name == "Result" and args.size == 1
    return ok(Types.Type.Result(try resolve_expanded(cx, st, args[0], true)))
  elsif name == "Task" and args.size == 1
    return ok(Types.Type.Task(try resolve_expanded(cx, st, args[0], true)))
  elsif name == "Channel" and args.size == 1
    return ok(Types.Type.Channel(try resolve_expanded(cx, st, args[0], false)))
  elsif name == "Lazy" and args.size == 1
    return ok(Types.Type.Lazy(try resolve_expanded(cx, st, args[0], false)))
  elsif name == "Fn"
    return resolve_function(cx, st, args)
  elsif name == "List" and args.size == 1
    return ok(Types.Type.List(try resolve_expanded(cx, st, args[0], false)))
  elsif name == "Map" and args.size == 2
    return resolve_map(cx, st, args)
  elsif name == "ATS" and args.size == 2
    return resolve_ats(cx, st, args)
  elsif name == "Set" and args.size == 1
    return resolve_set(cx, st, args[0])
  end

  return resolve_generic(cx, st, ref)
end

# The type resolved when it has no arguments: a type parameter, Void, a primitive, a handle, a resource, an enum or a
# struct.
def resolve_plain(cx: State.Cx, st: State.St, ref: TypeRef, completion: Bool) -> Result[ResolvedType]
  name = ref.name
  if cx.type_params.any? do |parameter: String| parameter == name end
    return ok(Types.Type.Var(name))
  elsif name == "Void"
    if !completion
      return error(State.fail(cx, st, "CHECK-VOID-TYPE", "Void is only valid in a completion type position", ref.span))
    end

    return ok(Types.Type.Void)
  elsif name == "Int"
    return ok(Types.Type.Int)
  elsif name == "Float"
    return ok(Types.Type.Float)
  elsif name == "Bool"
    return ok(Types.Type.Bool)
  elsif name == "String"
    return ok(Types.Type.String)
  elsif name == "Nil"
    return ok(Types.Type.Nil)
  elsif name == "Json"
    return ok(Types.Type.Json)
  elsif name == "Range"
    return ok(Types.Type.Range)
  elsif OPAQUE_TYPES.include?(name) or cx.resources.include?(name)
    return ok(Types.Type.Opaque(name))
  end

  return resolve_generic(cx, st, ref)
end

def resolve_function(cx: State.Cx, st: State.St, args: List[TypeRef]) -> Result[ResolvedType]
  params: List[ResolvedType] = []
  index = 0
  while index < args.size - 1
    params = params.push(try resolve_expanded(cx, st, args[index], false))
    index += 1
  end

  result = try resolve_expanded(cx, st, args[args.size - 1], true)
  return ok(Types.Type.Fn(params, result))
end

def resolve_map(cx: State.Cx, st: State.St, args: List[TypeRef]) -> Result[ResolvedType]
  key = try resolve_expanded(cx, st, args[0], false)
  if !key_here?(cx, key)
    return error(
      State.fail(
        cx,
        st,
        "CHECK-MAP-KEY-TYPE",
        "a Map key must be Int or String, found #{Types.to_text(key)}",
        args[0].span,
      ),
    )
  end

  return ok(Types.Type.Map(key, try resolve_expanded(cx, st, args[1], false)))
end

# ATS[K, V]: the key as a Map key, and a value that ats_value? accepts (CHECK-ATS-VALUE on the value type).
def resolve_ats(cx: State.Cx, st: State.St, args: List[TypeRef]) -> Result[ResolvedType]
  map = try resolve_map(cx, st, args)
  value = Types.value(map)
  if !ats_value?(cx, value)
    return error(ats_value_failure(cx, st, value, args[1].span))
  end

  return ok(Types.Type.ATS(Types.key(map), value))
end

def resolve_set(cx: State.Cx, st: State.St, arg: TypeRef) -> Result[ResolvedType]
  element = try resolve_expanded(cx, st, arg, false)
  if !key_here?(cx, element)
    return error(
      State.fail(
        cx,
        st,
        "CHECK-SET-ELEMENT-TYPE",
        "a Set element must be Int or String, found #{Types.to_text(element)}",
        arg.span,
      ),
    )
  end

  return ok(Types.Type.Set(element))
end

# An enum (with its type arguments), a struct, or the unknown type.
def resolve_generic(cx: State.Cx, st: State.St, ref: TypeRef) -> Result[ResolvedType]
  name = ref.name
  definition = cx.enums.get(name)
  if definition.ok?
    parameters = definition.unwrap!.parameters
    if parameters.size != ref.args.size
      return error(
        State.fail(
          cx,
          st,
          "CHECK-UNKNOWN-TYPE",
          "enum #{Types.display_name(name)} #{expects_text(parameters.size, ref.args.size)}",
          ref.span,
        ),
      )
    end

    args: List[ResolvedType] = []
    for arg in ref.args
      args = args.push(try resolve_expanded(cx, st, arg, false))
    end

    return ok(Types.Type.Enum(name, args))
  elsif cx.structs.has_key?(name) and ref.args.size == 0
    return ok(Types.Type.Struct(name))
  end

  candidates = cx.structs.keys.concat(cx.enums.keys)
  help = Help.foreign(cx.help, name)
  if help == ""
    help = Help.near(name, candidates, shared_type_names(cx))
  end

  return error(
    State.fail_maybe(
      cx,
      st,
      "CHECK-UNKNOWN-TYPE",
      "unknown type \"#{Types.display_name(name)}\"",
      ref.span,
      help,
    ),
  )
end

# The type names offered as a guess for an unknown type besides the structs and enums.
def shared_type_names(cx: State.Cx) -> List[String]
  return [
    "Int",
    "Float",
    "Bool",
    "String",
    "Nil",
    "Void",
    "List",
    "Map",
    "Set",
    "Result",
    "Json",
    "Fn",
    "Task",
    "Channel",
    "Lazy",
    "ATS",
    "Range",
  ].concat(OPAQUE_TYPES.to_a)
end

# True when every field of the struct passes the test: 0 for encodable, 1 for decodable. A struct already in seen is
# true (the type is recursive).
def struct_all?(cx: State.Cx, name: String, seen: List[String], test: Int) -> Bool
  if seen.any? do |item: String| item == name end
    return true
  end

  inner = seen.push(name)
  for field in cx.structs[name]
    if test == 0 and !encodable?(cx, field.type, inner)
      return false
    elsif test == 1 and !decodable?(cx, field.type, inner)
      return false
    end
  end

  return true
end

def nominal_data?(cx: State.Cx, type: ResolvedType, seen: List[String]) -> Bool
  name = Types.name(type)
  key = "#{Types.tag(type)}:#{name}"
  for argument in Types.args(type)
    builtin_void = Types.is?(argument, "Void") and ENUMS.has_key?(name)
    if !builtin_void and !data?(cx, argument, seen)
      return false
    end
  end

  if seen.any? do |item: String| item == key end
    return true
  end

  inner = seen.push(key)
  if Types.is?(type, "Struct")
    for field in cx.structs[name]
      if !data?(cx, field.type, inner)
        return false
      end
    end

    return true
  end

  for variant in cx.enums[name].variants
    for payload in variant.payload
      if !data?(cx, payload, inner)
        return false
      end
    end
  end

  return true
end

def substitution(type: ResolvedType, name: String, substitutions: Map[String, ResolvedType]) -> ResolvedType
  found = substitutions.get(name)
  if found.ok?
    return found.unwrap!
  end

  return type
end

# True for a type with other types inside: the ones unify matches part by part.
def composite?(type: ResolvedType) -> Bool
  return parts(type).size > 0
end

# unify for two types with the same head: the arguments pair by pair. An enum must have the same name.
def unify_inside(
  cx: State.Cx,
  st: State.St,
  template: ResolvedType,
  actual: ResolvedType,
  substitutions: Map[String, ResolvedType],
  span: Source.Span,
) -> Result[Map[String, ResolvedType]]
  pairs = parts(template)
  others = parts(actual)
  if Types.is?(template, "Enum") and Types.name(template) != Types.name(actual)
    try State.ensure(cx, st, actual, template, span)
  end

  if pairs.size != others.size
    try State.ensure(cx, st, actual, template, span)
  end

  found = substitutions
  index = 0
  while index < pairs.size
    found = try unify(cx, st, pairs[index], others[index], found, span)
    index += 1
  end

  return ok(found)
end

# The types inside a type, in order: the item, the key and value, the parameters then the result, the type arguments.
def parts(type: ResolvedType) -> List[ResolvedType]
  case type
    Types.Type.Result(item) -> return [item]
    Types.Type.Task(item) -> return [item]
    Types.Type.Channel(item) -> return [item]
    Types.Type.Lazy(item) -> return [item]
    Types.Type.List(item) -> return [item]
    Types.Type.Set(item) -> return [item]
    Types.Type.Map(key, value) -> return [key, value]
    Types.Type.ATS(key, value) -> return [key, value]
    Types.Type.Fn(params, result) -> return params.concat([result])
    Types.Type.Enum(name, args) -> return args
    _ -> return []
  end
end
