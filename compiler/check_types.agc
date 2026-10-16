## Types in the checker: reading a type written in the source (resolve_type), the questions the rules ask of a type
## (can it be printed, encoded to JSON, decoded from JSON), and the type variables of generic enums (substitute,
## unify). These are the helpers that do not depend on the walk of the tree.

import Ast from "ast"
import Help from "check_help"
import State from "check_state"
import Source from "source"
import Types from "types"

## The type a type written in the source stands for. completion says Void is allowed here (a result type, or the item
## of a Result or Task). The first problem is CHECK-VOID-TYPE, CHECK-MAP-KEY-TYPE, CHECK-SET-ELEMENT-TYPE or
## CHECK-UNKNOWN-TYPE.
export def resolve_type(cx: State.Cx, st: State.St, ref: Ast.TypeRef, completion: Bool) -> Result[Types.Type]
  name = ref.name
  args = ref.args
  if args.size == 0
    return resolve_plain(cx, st, ref, completion)
  end
  if name == "Result" and args.size == 1
    return ok(Types.Type.Result(try resolve_type(cx, st, args[0], true)))
  elsif name == "Task" and args.size == 1
    return ok(Types.Type.Task(try resolve_type(cx, st, args[0], true)))
  elsif name == "Channel" and args.size == 1
    return ok(Types.Type.Channel(try resolve_type(cx, st, args[0], false)))
  elsif name == "Fn"
    return resolve_function(cx, st, args)
  elsif name == "List" and args.size == 1
    return ok(Types.Type.List(try resolve_type(cx, st, args[0], false)))
  elsif name == "Map" and args.size == 2
    return resolve_map(cx, st, args)
  elsif name == "Set" and args.size == 1
    return resolve_set(cx, st, args[0])
  end
  return resolve_generic(cx, st, ref)
end

## The types of several type references, in order.
export def resolve_all(cx: State.Cx, st: State.St, refs: List[Ast.TypeRef]) -> Result[List[Types.Type]]
  out: List[Types.Type] = []
  for ref in refs
    out = out.push(try resolve_type(cx, st, ref, false))
  end
  return ok(out)
end

## True for Int and String, the types of a Map key or a Set element.
export def key_type?(type: Types.Type) -> Bool
  return Types.is(type, "Int") or Types.is(type, "String")
end

## True when the type may be a Map key or a Set element where cx checks: Int and String, and in the files of the
## prelude a type variable too (the checker has checked the types it stands for, check_prelude.agc).
export def key_here?(cx: State.Cx, type: Types.Type) -> Bool
  return key_type?(type) or (cx.prelude and Types.is(type, "Var"))
end

## True for Int and Float.
export def numeric?(type: Types.Type) -> Bool
  return Types.is(type, "Int") or Types.is(type, "Float")
end

## True for Int, Float, Bool, String and Nil, the types that == compares.
export def primitive?(type: Types.Type) -> Bool
  return numeric?(type) or Types.is(type, "Bool") or Types.is(type, "String") or Types.is(type, "Nil")
end

## True when JSON.encode can write a value of the type: primitives, Json, lists, maps with String keys, and structs of
## those.
export def encodable?(cx: State.Cx, type: Types.Type, seen: List[String]) -> Bool
  if primitive?(type) or Types.is(type, "Json")
    return true
  elsif Types.is(type, "List")
    return encodable?(cx, Types.item(type), seen)
  elsif Types.is(type, "Map")
    return Types.is(Types.key(type), "String") and encodable?(cx, Types.value(type), seen)
  elsif Types.is(type, "Struct")
    return struct_all?(cx, Types.name(type), seen, 0)
  end
  return false
end

## True when JSON.decode can read a value of the type: Int, Float, Bool, String, lists, maps with String keys, and
## structs of those.
export def decodable?(cx: State.Cx, type: Types.Type, seen: List[String]) -> Bool
  if Types.is(type, "Int") or Types.is(type, "Float") or Types.is(type, "Bool") or Types.is(type, "String")
    return true
  elsif Types.is(type, "List")
    return decodable?(cx, Types.item(type), seen)
  elsif Types.is(type, "Map")
    return Types.is(Types.key(type), "String") and decodable?(cx, Types.value(type), seen)
  elsif Types.is(type, "Struct")
    return struct_all?(cx, Types.name(type), seen, 1)
  end
  return false
end

## True for a type that has to_s: the data types. Numbers, Bool, String, nil, Json, ranges, type variables, and lists,
## maps, sets, Results, structs and enums of those. seen holds the structs and enums already being looked at
## ("Struct:name"), so a recursive type ends.
export def data?(cx: State.Cx, type: Types.Type, seen: List[String]) -> Bool
  if primitive?(type) or Types.is(type, "Json") or Types.is(type, "Range") or Types.is(type, "Var")
    return true
  elsif Types.is(type, "List")
    return data?(cx, Types.item(type), seen)
  elsif Types.is(type, "Map")
    return data?(cx, Types.key(type), seen) and data?(cx, Types.value(type), seen)
  elsif Types.is(type, "Set")
    return true
  elsif Types.is(type, "Result")
    return Types.is(Types.item(type), "Void") or data?(cx, Types.item(type), seen)
  elsif Types.is(type, "Struct") or Types.is(type, "Enum")
    return nominal_data?(cx, type, seen)
  end
  return false
end

## True when the type has a type variable inside.
export def has_variables?(type: Types.Type) -> Bool
  case type
    Types.Type.Var(name) -> return true
    Types.Type.Result(item) -> return has_variables?(item)
    Types.Type.Task(item) -> return has_variables?(item)
    Types.Type.Channel(item) -> return has_variables?(item)
    Types.Type.List(item) -> return has_variables?(item)
    Types.Type.Set(item) -> return has_variables?(item)
    Types.Type.Map(key, value) -> return has_variables?(key) or has_variables?(value)
    Types.Type.Fn(params, result) ->
      return params.any? do |param: Types.Type| has_variables?(param) end or has_variables?(result)
    Types.Type.Enum(name, args) -> return args.any? do |arg: Types.Type| has_variables?(arg) end
    _ -> return false
  end
end

## The type with each type variable that has a substitution replaced.
export def substitute(type: Types.Type, substitutions: Map[String, Types.Type]) -> Types.Type
  case type
    Types.Type.Var(name) -> return substitution(type, name, substitutions)
    Types.Type.Result(item) -> return Types.Type.Result(substitute(item, substitutions))
    Types.Type.Task(item) -> return Types.Type.Task(substitute(item, substitutions))
    Types.Type.Channel(item) -> return Types.Type.Channel(substitute(item, substitutions))
    Types.Type.List(item) -> return Types.Type.List(substitute(item, substitutions))
    Types.Type.Set(item) -> return Types.Type.Set(substitute(item, substitutions))
    Types.Type.Map(key, value) -> return Types.Type.Map(
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
export def substitute_all(types: List[Types.Type], substitutions: Map[String, Types.Type]) -> List[Types.Type]
  return types.map do |type: Types.Type| substitute(type, substitutions) end
end

## Matches the actual type against a template that may have type variables, and returns the substitutions with what the
## match learned. A variable already set must match again; a template with no variable must equal the actual type, else
## CHECK-TYPE-MISMATCH.
export def unify(
  cx: State.Cx,
  st: State.St,
  template: Types.Type,
  actual: Types.Type,
  substitutions: Map[String, Types.Type],
  span: Source.Span,
) -> Result[Map[String, Types.Type]]
  if Types.is(template, "Var")
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

# The type resolved when it has no arguments: a type parameter, Void, a primitive, a handle, an enum or a struct.
def resolve_plain(cx: State.Cx, st: State.St, ref: Ast.TypeRef, completion: Bool) -> Result[Types.Type]
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
  elsif cx.catalog.opaque.include?(name)
    return ok(Types.Type.Opaque(name))
  end
  return resolve_generic(cx, st, ref)
end

def resolve_function(cx: State.Cx, st: State.St, args: List[Ast.TypeRef]) -> Result[Types.Type]
  params: List[Types.Type] = []
  index = 0
  while index < args.size - 1
    params = params.push(try resolve_type(cx, st, args[index], false))
    index += 1
  end
  result = try resolve_type(cx, st, args[args.size - 1], true)
  return ok(Types.Type.Fn(params, result))
end

def resolve_map(cx: State.Cx, st: State.St, args: List[Ast.TypeRef]) -> Result[Types.Type]
  key = try resolve_type(cx, st, args[0], false)
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
  return ok(Types.Type.Map(key, try resolve_type(cx, st, args[1], false)))
end

def resolve_set(cx: State.Cx, st: State.St, arg: Ast.TypeRef) -> Result[Types.Type]
  element = try resolve_type(cx, st, arg, false)
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
def resolve_generic(cx: State.Cx, st: State.St, ref: Ast.TypeRef) -> Result[Types.Type]
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
          "enum #{Types.display_name(name)} expects #{parameters.size} type argument(s), found #{ref.args.size}",
          ref.span,
        ),
      )
    end
    return ok(Types.Type.Enum(name, try resolve_all(cx, st, ref.args)))
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
    "Range",
  ].concat(cx.catalog.opaque.to_a)
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

def nominal_data?(cx: State.Cx, type: Types.Type, seen: List[String]) -> Bool
  name = Types.name(type)
  key = "#{Types.tag(type)}:#{name}"
  for argument in Types.args(type)
    builtin_void = Types.is(argument, "Void") and cx.catalog.enums.has_key?(name)
    if !builtin_void and !data?(cx, argument, seen)
      return false
    end
  end
  if seen.any? do |item: String| item == key end
    return true
  end
  inner = seen.push(key)
  if Types.is(type, "Struct")
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

def substitution(type: Types.Type, name: String, substitutions: Map[String, Types.Type]) -> Types.Type
  found = substitutions.get(name)
  if found.ok?
    return found.unwrap!
  end
  return type
end

# True for a type with other types inside: the ones unify matches part by part.
def composite?(type: Types.Type) -> Bool
  return parts(type).size > 0
end

# unify for two types with the same head: the arguments pair by pair. An enum must have the same name.
def unify_inside(
  cx: State.Cx,
  st: State.St,
  template: Types.Type,
  actual: Types.Type,
  substitutions: Map[String, Types.Type],
  span: Source.Span,
) -> Result[Map[String, Types.Type]]
  pairs = parts(template)
  others = parts(actual)
  if Types.is(template, "Enum") and Types.name(template) != Types.name(actual)
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
def parts(type: Types.Type) -> List[Types.Type]
  case type
    Types.Type.Result(item) -> return [item]
    Types.Type.Task(item) -> return [item]
    Types.Type.Channel(item) -> return [item]
    Types.Type.List(item) -> return [item]
    Types.Type.Set(item) -> return [item]
    Types.Type.Map(key, value) -> return [key, value]
    Types.Type.Fn(params, result) -> return params.concat([result])
    Types.Type.Enum(name, args) -> return args
    _ -> return []
  end
end
