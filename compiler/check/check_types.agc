## Types in the checker: reading a type written in the source (resolve_type), the questions the rules ask of a type
## (can it be printed, encoded to JSON, decoded from JSON), and the type variables of generic structs and enums
## (substitute, unify). These are the helpers that do not depend on the walk of the tree.

import Model from "../catalog/builtin_model"
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

# What place_walk found: the place ("" for none) and the structs walked so far.
struct Placed
  place: String
  seen: Map[String, Bool]
end

# What a walk of a type found: whether the test passed, and the structs walked so far (see struct_walk).
struct Walk
  passes: Bool
  seen: Map[String, Bool]
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
## ("Wrapper.items", "" outside a struct). Runs before the decodable and encodable tests.
export def json_field_place(cx: State.Cx, type: ResolvedType, direct: Bool, kind: String, owner: String) -> String
  return place_walk(cx, type, direct, kind, owner, {}).place
end

## True when JSON.encode can write a value of the type: primitives, Json, lists, maps with String keys, structs of
## those (a generic struct by its fields with the type arguments put in), and JsonField of an encodable type other than
## Nil.
export def encodable?(cx: State.Cx, type: ResolvedType) -> Bool
  return encode_walk(cx, type, {}).passes
end

## True when JSON.decode can read a value of the type: Int, Float, Bool, String, lists, maps with String keys, plain
## structs of those, and JsonField of a decodable type (Nil is not one). A generic struct is not decodable: the schema
## of the structs is keyed by their bare names, which Box[Int] and Box[String] would share.
export def decodable?(cx: State.Cx, type: ResolvedType) -> Bool
  return decode_walk(cx, type, {}).passes
end

## True when the type may be the value of an ATS: a data type (data?, a deep walk that rejects Fn, Task, Channel, every
## handle and ATS itself, so no table holds a table) that is not Nil and has no type variable. A variable is allowed
## only where it is checked later: in the target of a generic alias (cx.prelude), whose uses are checked expanded. A
## generic enum checks its arguments only with data?, which accepts a variable, so a payload ATS[String, T] is refused.
export def ats_value?(cx: State.Cx, type: ResolvedType) -> Bool
  if Types.is?(type, "Nil") or !data?(cx, type)
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

## True for a type that has to_s: the data types. Numbers, Bool, String, nil, Json, ranges, and lists, maps, sets,
## Results, structs and enums of those. A type variable is one only in the files of the prelude: in the body of a
## generic function it stands for any type, which could be an Fn.
export def data?(cx: State.Cx, type: ResolvedType) -> Bool
  return data_walk(cx, type, {}).passes
end

## True when the type has a type variable inside.
export def has_variables?(type: ResolvedType) -> Bool
  case type
    Types.Type.Var(name) -> return true
    Types.Type.Result(item) -> return has_variables?(item)
    Types.Type.Task(item) -> return has_variables?(item)
    Types.Type.Channel(item) -> return has_variables?(item)
    Types.Type.Lazy(item) -> return has_variables?(item)
    Types.Type.Codec(item) -> return has_variables?(item)
    Types.Type.List(item) -> return has_variables?(item)
    Types.Type.Set(item) -> return has_variables?(item)
    Types.Type.Map(key, value) -> return has_variables?(key) or has_variables?(value)
    Types.Type.ATS(key, value) -> return has_variables?(key) or has_variables?(value)
    Types.Type.Fn(params, result) ->
      return params.any? do |param: ResolvedType| has_variables?(param) end or has_variables?(result)
    Types.Type.Struct(name, args) -> return args.any? do |arg: ResolvedType| has_variables?(arg) end
    Types.Type.Enum(name, args) -> return args.any? do |arg: ResolvedType| has_variables?(arg) end
    _ -> return false
  end
end

## True when the template has a type variable that substitutions does not set yet. A template is the signature of a
## function or the type of a field: every variable in it is a parameter of the declaration, whatever the types in
## substitutions hold (they may hold the variables of the code that calls).
export def open_variables?(template: ResolvedType, substitutions: Map[String, ResolvedType]) -> Bool
  return variable_names(template).any? do |name: String| !substitutions.has_key?(name) end
end

## The names of the type variables written in the type, in order, with repeats.
export def variable_names(type: ResolvedType) -> List[String]
  if Types.is?(type, "Var")
    return [Types.name(type)]
  end

  names: List[String] = []
  for part in parts(type)
    names = names.concat(variable_names(part))
  end

  return names
end

## True when the type has Void where a value is needed. Void is valid as the result of a function type, the last type
## of an Fn, and the item of a Result or a Task: completion says the type is in such a place.
export def misplaced_void?(type: ResolvedType, completion: Bool) -> Bool
  case type
    Types.Type.Void -> return !completion
    Types.Type.Result(item) -> return misplaced_void?(item, true)
    Types.Type.Task(item) -> return misplaced_void?(item, true)
    Types.Type.Fn(params, result) ->
      return params.any? do |param: ResolvedType| misplaced_void?(param, false) end or misplaced_void?(result, true)
    _ -> return parts(type).any? do |part: ResolvedType| misplaced_void?(part, false) end
  end
end

## Matches the actual type against a template and returns the substitutions with the variables of the template that it
## binds and substitutions does not set yet. It is unify without the failures: a part that does not match is left to
## the check that follows, and a variable is not bound to a type that is not known (Unknown, or with Unknown inside).
export def learn(
  template: ResolvedType,
  actual: ResolvedType,
  substitutions: Map[String, ResolvedType],
) -> Map[String, ResolvedType]
  if Types.is?(template, "Var")
    if substitutions.has_key?(Types.name(template)) or has_unknown?(actual)
      return substitutions
    end

    return substitutions.put(Types.name(template), actual)
  end

  pairs = parts(template)
  others = parts(actual)
  same_head = Types.tag(template) == Types.tag(actual) and pairs.size == others.size
  if same_head and (Types.is?(template, "Enum") or Types.is?(template, "Struct"))
    same_head = Types.name(template) == Types.name(actual)
  end

  found = substitutions
  index = 0
  while same_head and index < pairs.size
    found = learn(pairs[index], others[index], found)
    index += 1
  end

  return found
end

## The type with each type variable that has a substitution replaced.
export def substitute(type: ResolvedType, substitutions: Map[String, ResolvedType]) -> ResolvedType
  case type
    Types.Type.Var(name) -> return substitution(type, name, substitutions)
    Types.Type.Result(item) -> return Types.Type.Result(substitute(item, substitutions))
    Types.Type.Task(item) -> return Types.Type.Task(substitute(item, substitutions))
    Types.Type.Channel(item) -> return Types.Type.Channel(substitute(item, substitutions))
    Types.Type.Lazy(item) -> return Types.Type.Lazy(substitute(item, substitutions))
    Types.Type.Codec(item) -> return Types.Type.Codec(substitute(item, substitutions))
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
    Types.Type.Struct(name, args) -> return Types.Type.Struct(name, substitute_all(args, substitutions))
    Types.Type.Enum(name, args) -> return Types.Type.Enum(name, substitute_all(args, substitutions))
    _ -> return type
  end
end

## substitute for each type of a list.
export def substitute_all(types: List[ResolvedType], substitutions: Map[String, ResolvedType]) -> List[ResolvedType]
  return types.map do |type: ResolvedType| substitute(type, substitutions) end
end

## The substitutions that a list of type parameters and a list of type arguments of the same length make.
export def bindings(parameters: List[String], args: List[ResolvedType]) -> Map[String, ResolvedType]
  found: Map[String, ResolvedType] = {}
  index = 0
  while index < parameters.size and index < args.size
    found = found.put(parameters[index], args[index])
    index += 1
  end

  return found
end

## The fields of a struct type with its type arguments put in, in declaration order: a Box[Int] has `value: Int`.
## A plain struct has the fields as declared.
export def fields_of(cx: State.Cx, type: ResolvedType) -> List[Model.Named]
  name = Types.name(type)
  parameters = cx.struct_params.get(name, [])
  if parameters.size == 0 or parameters.size != Types.args(type).size
    return cx.structs[name]
  end

  substitutions = bindings(parameters, Types.args(type))
  return cx.structs[name].map do |field: Model.Named| field.with(type: substitute(field.type, substitutions)) end
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
  elsif name == "JSON.Codec" and args.size == 1
    return ok(Types.Type.Codec(try resolve_expanded(cx, st, args[0], false)))
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
  elsif cx.structs.has_key?(name) and cx.struct_params.get(name, []).size > 0
    return resolve_generic_struct(cx, st, ref)
  elsif cx.structs.has_key?(name) and ref.args.size == 0
    return ok(Types.Type.Struct(name, []))
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

# A generic struct with its type arguments: one per type parameter, CHECK-UNKNOWN-TYPE otherwise (a bare Box too).
def resolve_generic_struct(cx: State.Cx, st: State.St, ref: TypeRef) -> Result[ResolvedType]
  parameters = cx.struct_params[ref.name]
  if parameters.size != ref.args.size
    return error(
      State.fail(
        cx,
        st,
        "CHECK-UNKNOWN-TYPE",
        "struct #{Types.display_name(ref.name)} #{expects_text(parameters.size, ref.args.size)}",
        ref.span,
      ),
    )
  end

  args: List[ResolvedType] = []
  for arg in ref.args
    args = args.push(try resolve_expanded(cx, st, arg, false))
  end

  return ok(Types.Type.Struct(ref.name, args))
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

# json_field_place for one type. seen holds every struct walked in the whole call (place_key), not only the ones on
# the path: the walk stops at the first place found, so a struct walked before had none, and a recursive type ends.
# A JsonField that is the argument of a struct is placed by the fields of the struct with the argument put in
# (place_fields): Box[JsonField[Int]] has a direct JsonField field `value`, and a list item for `items: List[T]`.
def place_walk(
  cx: State.Cx, type: ResolvedType, direct: Bool, kind: String, owner: String, seen: Map[String, Bool]
) -> Placed
  if json_field?(type)
    if !direct
      if owner == ""
        return Placed(place: kind, seen: seen)
      end

      return Placed(place: "#{kind} in #{owner}", seen: seen)
    end

    return place_walk(cx, Types.args(type)[0], false, "nested JsonField", owner, seen)
  elsif Types.is?(type, "List")
    return place_walk(cx, Types.item(type), false, "list item", owner, seen)
  elsif Types.is?(type, "Map")
    return place_walk(cx, Types.value(type), false, "map value", owner, seen)
  elsif Types.is?(type, "Struct") and cx.structs.has_key?(Types.name(type))
    key = place_key(type)
    # The type arguments come first and whether or not the struct was seen: Box[Box[JsonField[Int]]] reaches the inner
    # Box by an argument, and the fields below are walked once for each key. A JsonField argument is walked as a
    # direct type here and placed by the fields below, which see it in the place of the parameter.
    for argument in Types.args(type)
      found = place_walk(cx, argument, json_field?(argument), "type argument", owner, seen)
      if found.place != ""
        return found
      end

      seen = found.seen
    end

    if seen.has_key?(key)
      return Placed(place: "", seen: seen)
    end

    seen = seen.put(key, true)
    place = Types.display_name(Types.name(type))
    for field in place_fields(cx, type)
      found = place_walk(cx, field.type, true, "struct field", "#{place}.#{field.name}", seen)
      if found.place != ""
        return found
      end

      seen = found.seen
    end
  end

  return Placed(place: "", seen: seen)
end

# The name of a struct type and a J for each JsonField argument and an I for each other one ("Box[J]"): what the
# stand-ins of place_fields tell apart, so Box[Int] and Box[JsonField[Int]] are walked once each.
def place_key(type: ResolvedType) -> String
  name = Types.name(type)
  if Types.args(type).size == 0
    return "Struct:#{name}"
  end

  marks = ""
  for argument in Types.args(type)
    if json_field?(argument)
      marks += "J"
    else
      marks += "I"
    end
  end

  return "Struct:#{name}[#{marks}]"
end

# The fields of a struct type to place after its type arguments were walked: each type parameter is replaced by a
# stand-in, JsonField[Int] for a JsonField argument and Int for any other (a nest of generic instances is then walked
# once for each level, as in stand_in_fields). The arguments were walked as types of their own, so what is inside a
# JsonField or a container is already placed.
def place_fields(cx: State.Cx, type: ResolvedType) -> List[Model.Named]
  name = Types.name(type)
  parameters = cx.struct_params.get(name, [])
  if parameters.size == 0 or parameters.size != Types.args(type).size
    return cx.structs[name]
  end

  stand: Map[String, ResolvedType] = {}
  index = 0
  while index < parameters.size
    if json_field?(Types.args(type)[index])
      stand = stand.put(parameters[index], Types.Type.Enum("JsonField", [Types.Type.Int]))
    else
      stand = stand.put(parameters[index], Types.Type.Int)
    end

    index += 1
  end

  return cx.structs[name].map do |field: Model.Named| field.with(type: substitute(field.type, stand)) end
end

def passed(seen: Map[String, Bool]) -> Walk
  return Walk(passes: true, seen: seen)
end

def refused(seen: Map[String, Bool]) -> Walk
  return Walk(passes: false, seen: seen)
end

def encode_walk(cx: State.Cx, type: ResolvedType, seen: Map[String, Bool]) -> Walk
  if primitive?(type) or Types.is?(type, "Json")
    return passed(seen)
  elsif json_field?(type)
    if Types.is?(Types.args(type)[0], "Nil")
      return refused(seen)
    end

    return encode_walk(cx, Types.args(type)[0], seen)
  elsif Types.is?(type, "List")
    return encode_walk(cx, Types.item(type), seen)
  elsif Types.is?(type, "Map")
    if !Types.is?(Types.key(type), "String")
      return refused(seen)
    end

    return encode_walk(cx, Types.value(type), seen)
  elsif Types.is?(type, "Struct")
    return struct_walk(cx, type, seen, 0)
  end

  return refused(seen)
end

def decode_walk(cx: State.Cx, type: ResolvedType, seen: Map[String, Bool]) -> Walk
  if Types.is?(type, "Int") or Types.is?(type, "Float") or Types.is?(type, "Bool") or Types.is?(type, "String")
    return passed(seen)
  elsif json_field?(type)
    return decode_walk(cx, Types.args(type)[0], seen)
  elsif Types.is?(type, "List")
    return decode_walk(cx, Types.item(type), seen)
  elsif Types.is?(type, "Map")
    if !Types.is?(Types.key(type), "String")
      return refused(seen)
    end

    return decode_walk(cx, Types.value(type), seen)
  elsif Types.is?(type, "Struct")
    if Types.args(type).size != 0
      return refused(seen)
    end

    return struct_walk(cx, type, seen, 1)
  end

  return refused(seen)
end

# data? for one type. seen holds every struct and enum walked in the whole call ("Struct:name"), not only the ones on
# the path (struct_walk says why that is sound), and a recursive type ends.
def data_walk(cx: State.Cx, type: ResolvedType, seen: Map[String, Bool]) -> Walk
  if primitive?(type) or Types.is?(type, "Json") or Types.is?(type, "Range")
    return passed(seen)
  elsif Types.is?(type, "Var")
    return Walk(passes: cx.prelude, seen: seen)
  elsif Types.is?(type, "List")
    return data_walk(cx, Types.item(type), seen)
  elsif Types.is?(type, "Map")
    key = data_walk(cx, Types.key(type), seen)
    if !key.passes
      return key
    end

    return data_walk(cx, Types.value(type), key.seen)
  elsif Types.is?(type, "Set")
    return passed(seen)
  elsif Types.is?(type, "Result")
    if Types.is?(Types.item(type), "Void")
      return passed(seen)
    end

    return data_walk(cx, Types.item(type), seen)
  elsif Types.is?(type, "Struct") or Types.is?(type, "Enum")
    return nominal_walk(cx, type, seen)
  end

  return refused(seen)
end

# The walk of a struct type for the test: 0 for encodable, 1 for decodable. The type arguments are tested first, each
# as a type of its own, whether or not the struct was seen (Box[Box[Fn[Int, Int]]] reaches the inner Box by an
# argument). Then every field is tested with a stand-in for each argument (stand_in_fields), once for each key in the
# whole call (walk_key: the name and which arguments are Nil, the one thing the stand-ins keep), so W[Int] and W[Nil]
# are walked once each and a JsonField[Nil] behind W[Nil] is found. seen is passed in and returned, and it holds every
# key entered so far, not only the keys on the path: a cluster of structs that use one another is walked once and not
# once for each path through it. That is sound because a walk is a conjunction that stops at the first failure: a key
# entered before either passed or aborted the whole walk, and a key still being walked counts as passed, as the type is
# recursive. A key has only two shapes for each parameter, so a recursion that changes its type arguments each time
# (W[T] with a field W[List[T]]) still ends. A decodable struct has no arguments.
def struct_walk(cx: State.Cx, type: ResolvedType, seen: Map[String, Bool], test: Int) -> Walk
  if test == 0
    for argument in Types.args(type)
      found = encode_walk(cx, argument, seen)
      if !found.passes
        return found
      end

      seen = found.seen
    end
  end

  key = walk_key(type)
  if seen.has_key?(key)
    return passed(seen)
  end

  seen = seen.put(key, true)
  for field in stand_in_fields(cx, type)
    found = test_walk(cx, field.type, seen, test)
    if !found.passes
      return found
    end

    seen = found.seen
  end

  return passed(seen)
end

# encode_walk for test 0, decode_walk for test 1.
def test_walk(cx: State.Cx, type: ResolvedType, seen: Map[String, Bool], test: Int) -> Walk
  if test == 0
    return encode_walk(cx, type, seen)
  end

  return decode_walk(cx, type, seen)
end

# The name of a struct type and an N for each Nil argument and an I for each other one ("W[IN]"): what the stand-ins
# (stand_ins) tell apart, so the walks of W[Int] and W[Nil] do not stop one another.
def walk_key(type: ResolvedType) -> String
  name = Types.name(type)
  if Types.args(type).size == 0
    return name
  end

  marks = ""
  for argument in Types.args(type)
    if Types.is?(argument, "Nil")
      marks += "N"
    else
      marks += "I"
    end
  end

  return "#{name}[#{marks}]"
end

def nominal_walk(cx: State.Cx, type: ResolvedType, seen: Map[String, Bool]) -> Walk
  name = Types.name(type)
  key = "#{Types.tag(type)}:#{name}"
  for argument in Types.args(type)
    builtin_void = Types.is?(argument, "Void") and ENUMS.has_key?(name)
    if !builtin_void
      found = data_walk(cx, argument, seen)
      if !found.passes
        return found
      end

      seen = found.seen
    end
  end

  if seen.has_key?(key)
    return passed(seen)
  end

  seen = seen.put(key, true)
  if Types.is?(type, "Struct")
    for field in stand_in_fields(cx, type)
      found = data_walk(cx, field.type, seen)
      if !found.passes
        return found
      end

      seen = found.seen
    end

    return passed(seen)
  end

  definition = cx.enums[name]
  stand = stand_ins(definition.parameters, Types.args(type))
  for variant in definition.variants
    for payload in variant.payload
      found = data_walk(cx, substitute(payload, stand), seen)
      if !found.passes
        return found
      end

      seen = found.seen
    end
  end

  return passed(seen)
end

# The fields of a struct type to walk after its type arguments were tested: each type parameter is replaced by a
# stand-in (stand_ins), not by its argument, so a nest of generic instances is walked once for each level and not once
# for each way down (the arguments are tested as types of their own, and repeating that for each field makes it
# exponential).
def stand_in_fields(cx: State.Cx, type: ResolvedType) -> List[Model.Named]
  name = Types.name(type)
  parameters = cx.struct_params.get(name, [])
  if parameters.size == 0 or parameters.size != Types.args(type).size
    return cx.structs[name]
  end

  stand = stand_ins(parameters, Types.args(type))
  return cx.structs[name].map do |field: Model.Named| field.with(type: substitute(field.type, stand)) end
end

# A type for each parameter to stand for its argument once the argument was tested: Int, or Nil for a Nil argument,
# the one thing that a field of the parameter (JsonField[T]) tells apart.
def stand_ins(parameters: List[String], args: List[ResolvedType]) -> Map[String, ResolvedType]
  found: Map[String, ResolvedType] = {}
  index = 0
  while index < parameters.size and index < args.size
    stand = Types.Type.Int
    if Types.is?(args[index], "Nil")
      stand = Types.Type.Nil
    end

    found = found.put(parameters[index], stand)
    index += 1
  end

  return found
end

def substitution(type: ResolvedType, name: String, substitutions: Map[String, ResolvedType]) -> ResolvedType
  found = substitutions.get(name)
  if found.ok?
    return found.unwrap!
  end

  return type
end

# True for Unknown, or a type that has Unknown inside.
def has_unknown?(type: ResolvedType) -> Bool
  return Types.unknown?(type) or parts(type).any? do |part: ResolvedType| has_unknown?(part) end
end

# True for a type with other types inside: the ones unify matches part by part.
def composite?(type: ResolvedType) -> Bool
  return parts(type).size > 0
end

# unify for two types with the same head: the arguments pair by pair. A struct or an enum must have the same name.
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
  if (Types.is?(template, "Enum") or Types.is?(template, "Struct")) and Types.name(template) != Types.name(actual)
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
    Types.Type.Codec(item) -> return [item]
    Types.Type.List(item) -> return [item]
    Types.Type.Set(item) -> return [item]
    Types.Type.Map(key, value) -> return [key, value]
    Types.Type.ATS(key, value) -> return [key, value]
    Types.Type.Fn(params, result) -> return params.concat([result])
    Types.Type.Struct(name, args) -> return args
    Types.Type.Enum(name, args) -> return args
    _ -> return []
  end
end
