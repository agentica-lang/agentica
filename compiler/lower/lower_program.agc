## The struct and enum tables of the lowered program The program's structs come first, then the builtin records it
## uses, each in the order of the catalog; enums likewise, and their variants are numbered in table order.

import Model from "../catalog/builtin_model"
import {ENUMS, RECORDS, SEALED} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Types from "../syntax/types"
import Ir from "ir"
import State from "lower_state"
import {BUILTIN_STRUCTS, STRUCT_NEEDS} from "lower_tables"

## The builtin enum of an Optional value: none, and some with its item. The VM prints a variant of the enum named
## Optional as its name alone (none, some(1)).
OPTIONAL = Ir.EnumDef(
  name: "Optional",
  variants: [Ir.VariantDef(name: "None", size: 0), Ir.VariantDef(name: "Some", size: 1)],
  decodable: false,
  types: [],
)

## The tables, and what the lowering looks up in them. user_types maps each name in the tables to "Struct" or "Enum",
## structs gives the index and the fields of a struct by name, enum_index the index of an enum by name, variants the id
## of "Enum.Variant", and json_types the structs, enums and struct instances JSON.decode may build.
struct Tables
  structs: List[Ir.StructDef]
  enums: List[Ir.EnumDef]
  instances: List[Ir.InstanceDef]
  user_types: Map[String, String]
  infos: Map[String, State.StructInfo]
  enum_index: Map[String, Int]
  variants: Map[String, Int]
  json_types: Set[String]
end

## Builds the tables. decls are all the declarations of the program in order. used are the watched type names that the
## program writes or whose types some expression has (a builtin record or enum is in the tables only then). type_names
## are the types that functions use as a value, which is when the user structs and enums that JSON can build are looked
## for, and targets the types the checker gave them (lowering.agc json_targets): an alias counts by what it names, and
## a List or Map target gets a struct of its own (json_list_name).
def build(decls: List[Ast.Decl], used: Set[String], type_names: List[String], targets: List[Types.Type]) -> Tables
  struct_decls: List[Ast.StructDecl] = []
  enum_decls: List[Ast.EnumDecl] = []
  aliases: Map[String, Ast.TypeAliasDecl] = {}
  for decl in decls
    case decl
      Ast.Decl.Struct(node) -> struct_decls = struct_decls.push(node)
      Ast.Decl.Enum(node) -> enum_decls = enum_decls.push(node)
      Ast.Decl.TypeAlias(node) -> aliases = aliases.put(node.name, node)
      _ -> struct_decls = struct_decls
    end
  end

  if aliases.size > 0
    struct_decls = struct_decls.map do |node: Ast.StructDecl|
      params = Set.new(node.type_parameters)
      node.with(
        fields: node.fields.map do |field: Ast.FieldDecl| field.with(type: expanded(field.type, aliases, params)) end,
      )
    end

    enum_decls = enum_decls.map do |node: Ast.EnumDecl|
      params = Set.new(node.type_parameters)
      node.with(
        variants: node.variants.map do |variant: Ast.EnumVariant|
          variant.with(
            payload_types: variant.payload_types.map do |ref: Ast.TypeRef| expanded(ref, aliases, params) end,
          )
        end,
      )
    end
  end

  builtin_types = builtin_decodable()
  names = type_names
  for target in targets
    names = names.concat(struct_names_in(target))
  end

  found = user_decodable(struct_decls, enum_decls, builtin_types, names, targets)
  decodable = found.table
  wanted = used
  if decodable.values.any? do |types: List[Types.Type]| types.any? do |type: Types.Type| json_field?(type) end end
    # JSON.decode builds JSON.Field values, so the enum is in the table even when no expression names it.
    wanted = used.add("JSON.Field")
  end

  if decodable.values.any? do |types: List[Types.Type]| types.any? do |type: Types.Type| optional_in?(type) end end
    # The same for the Optional values that JSON.decode builds.
    wanted = wanted.add("Optional")
  end

  structs: List[Ir.StructDef] = []
  for decl in struct_decls
    fields = decl.fields.map do |field: Ast.FieldDecl| field.name end
    types: List[Types.Type] = []
    if decodable.has_key?(decl.name)
      types = decodable[decl.name]
    end

    known = decodable.has_key?(decl.name)
    structs = structs.push(Ir.StructDef(name: decl.name, fields: fields, decodable: known, types: types))
  end

  structs = structs.concat(builtin_structs(used, builtin_types)).concat(json_list_structs(targets, decodable))
  enums: List[Ir.EnumDef] = []
  for decl in enum_decls
    variants = decl.variants.map do |variant: Ast.EnumVariant|
      Ir.VariantDef(name: variant.name, size: variant.payload_types.size)
    end

    types: List[Types.Type] = []
    if decodable.has_key?(decl.name)
      types = decodable[decl.name]
    end

    known = decodable.has_key?(decl.name)
    enums = enums.push(Ir.EnumDef(name: decl.name, variants: variants, decodable: known, types: types))
  end

  if wanted.include?("Optional")
    enums = enums.push(OPTIONAL)
  end

  for name in ENUMS.keys
    if wanted.include?(name)
      variants = ENUMS[name].variants.map do |variant: Model.Variant|
        Ir.VariantDef(name: variant.name, size: variant.payload.size)
      end

      enums = enums.push(Ir.EnumDef(name: name, variants: variants, decodable: false, types: []))
    end
  end

  instances: List[Ir.InstanceDef] = []
  for key in found.instances.keys.sort
    if decodable.has_key?(key)
      type = found.instances[key]
      instances = instances.push(
        Ir.InstanceDef(name: key, struct_name: Types.name(type), type: type, types: decodable[key]),
      )
    end
  end

  index(structs, enums, instances)
end

## The name of the struct that stands for a List[T] or Map[String, T] used as a JSON.decode target, and of a generic
## struct instance: the type with its linked names, such as List[app.Person] or app.Box[Int] (Types.json_name). A `[`
## keeps it apart from every struct a program declares, and the VM decodes such a List or Map struct's one field in
## its place (docs/vm/03-ir-and-bytecode.md).
def json_list_name(type: Types.Type) -> String = Types.json_name(type)

private

# How deep the type arguments of a decodable generic struct instance may nest (Box[List[Int]] is 2); a deeper one, as a
# struct whose field passes itself a bigger argument makes, is not decodable. The checker has the same limit
# (check_types.agc).
MAX_INSTANCE_DEPTH = 32

# The field types that keep a builtin record from JSON.decode: an enum, a channel, and Bytes (JSON has no bytes:
# HttpWire.Request.body).
UNDECODABLE = Set.new(["Enum", "Channel", "Bytes", "Opaque"])

# What user_decodable finds: the field or payload types of the structs, enums and struct instances JSON.decode can
# build, by name (an instance by its json_list_name), and the type of each instance that was looked at.
struct Found
  table: Map[String, List[Types.Type]]
  instances: Map[String, Types.Type]
end

# The type with each alias replaced by the type it names, its parameters by the arguments written. A type parameter
# in params is never an alias, and the checker has refused a cycle.
def expanded(ref: Ast.TypeRef, aliases: Map[String, Ast.TypeAliasDecl], params: Set[String]) -> Ast.TypeRef
  args = ref.args.map do |arg: Ast.TypeRef| expanded(arg, aliases, params) end
  return ref.with(args: args) if params.include?(ref.name) or !aliases.has_key?(ref.name)

  alias = aliases[ref.name]
  return ref.with(args: args) if alias.type_parameters.size != args.size

  bound: Map[String, Ast.TypeRef] = {}
  for at in 0...args.size
    bound = bound.put(alias.type_parameters[at], args[at])
  end

  substituted(expanded(alias.target, aliases, Set.new(alias.type_parameters)), bound)
end

def substituted(ref: Ast.TypeRef, bound: Map[String, Ast.TypeRef]) -> Ast.TypeRef
  return bound[ref.name] if ref.args.size == 0 and bound.has_key?(ref.name)

  ref.with(args: ref.args.map do |arg: Ast.TypeRef| substituted(arg, bound) end)
end

# The lookups over the finished tables.
def index(structs: List[Ir.StructDef], enums: List[Ir.EnumDef], instances: List[Ir.InstanceDef]) -> Tables
  user_types: Map[String, String] = {}
  infos: Map[String, State.StructInfo] = {}
  json_types: Set[String] = Set.new([])
  at = 0
  for entry in structs
    positions: Map[String, Int] = {}
    place = 0
    for field in entry.fields
      positions = positions.put(field, place)
      place += 1
    end

    user_types = user_types.put(entry.name, "Struct")
    infos = infos.put(entry.name, State.StructInfo(index: at, fields: entry.fields, positions: positions))
    if entry.decodable
      json_types = json_types.add(entry.name)
    end

    at += 1
  end

  variants: Map[String, Int] = {}
  enum_index: Map[String, Int] = {}
  id = 0
  for entry in enums
    user_types = user_types.put(entry.name, "Enum")
    enum_index = enum_index.put(entry.name, enum_index.size)
    if entry.decodable
      json_types = json_types.add(entry.name)
    end

    for variant in entry.variants
      variants = variants.put("#{entry.name}.#{variant.name}", id)
      id += 1
    end
  end

  for instance in instances
    json_types = json_types.add(instance.name)
  end

  Tables(
    structs: structs,
    enums: enums,
    instances: instances,
    user_types: user_types,
    infos: infos,
    enum_index: enum_index,
    variants: variants,
    json_types: json_types,
  )
end

# One decodable struct of a single field for each List or Map target, named by json_list_name: the type table holds
# only the field types of structs and enums. decodable are the structs and enums JSON can build; a target with another
# struct or enum in it has none, so the lowering of its name refuses it as it refuses such a struct.
def json_list_structs(targets: List[Types.Type], decodable: Map[String, List[Types.Type]]) -> List[Ir.StructDef]
  found: List[Ir.StructDef] = []
  seen: Set[String] = Set.new([])
  for type in targets
    name = json_list_name(type)
    list = Types.is?(type, "List") or Types.is?(type, "Map")
    if list and !seen.include?(name) and references_known?([type], decodable)
      found = found.push(Ir.StructDef(name: name, fields: ["value"], decodable: true, types: [type]))
      seen = seen.add(name)
    end
  end

  found
end

# The field types of the builtin records JSON.decode can build: all but the sealed ones (Time.Date), which only their
# builtins build, and those with a field of an UNDECODABLE type.
def builtin_decodable() -> Map[String, List[Types.Type]]
  found: Map[String, List[Types.Type]] = {}
  for name in BUILTIN_STRUCTS
    types = RECORDS[name].map do |field: Model.Named| field.type end
    if !SEALED.include?(name) and !types.any? do |type: Types.Type| undecodable?(type) end
      found = found.put(name, types)
    end
  end

  found
end

# True for a field type JSON cannot hold: an UNDECODABLE one, alone or in an Optional (HttpWire.ClientOptions.tls).
def undecodable?(type: Types.Type) -> Bool
  case type
    Types.Type.Optional(item) -> undecodable?(item)
    _ -> UNDECODABLE.include?(Types.tag(type))
  end
end

# The builtin records the program uses, and the ones those have a field of, in the order of BUILTIN_STRUCTS.
def builtin_structs(used: Set[String], decodable: Map[String, List[Types.Type]]) -> List[Ir.StructDef]
  wanted: Set[String] = Set.new([])
  for name in BUILTIN_STRUCTS
    if used.include?(name)
      wanted = wanted.add(name)
      for needed in STRUCT_NEEDS.get(name, [])
        wanted = wanted.add(needed)
      end
    end
  end

  found: List[Ir.StructDef] = []
  for name in BUILTIN_STRUCTS
    if wanted.include?(name)
      fields = RECORDS[name].map do |field: Model.Named| field.name end
      types: List[Types.Type] = []
      if decodable.has_key?(name)
        types = decodable[name]
      end

      found = found.push(Ir.StructDef(name: name, fields: fields, decodable: decodable.has_key?(name), types: types))
    end
  end

  found
end

# The user structs and enums JSON.decode can build, with their field types, or for an enum the payload types of all
# its variants one after the other. Every type is an Int, a narrow integer, Float, Bool or String, or a List, a Map
# from String or an Optional of such a type or of a struct or enum that can be built itself. Only looked for when some
# function uses a type name as a value. A generic enum is left out: JSON.decode takes a bare name, and the checker
# refuses an instance.
# Every struct that can be built is kept, but an enum only when it is one of type_names or a struct or another
# kept enum
# has it in a field or payload, since the type table of such a struct names it. An instance of a generic struct
# (Box[Int]) is an entry of its own, by its json_list_name, with the field types of the struct for its arguments: the
# instances looked at are those of type_targets and those the fields of the entries name.
def user_decodable(
  structs: List[Ast.StructDecl],
  enums: List[Ast.EnumDecl],
  builtin: Map[String, List[Types.Type]],
  type_names: List[String],
  type_targets: List[Types.Type],
) -> Found
  return Found(table: {}, instances: {}) if type_names.size == 0

  kinds: Map[String, String] = {}
  for name in BUILTIN_STRUCTS
    kinds = kinds.put(name, "Struct")
  end

  for decl in structs
    kinds = kinds.put(decl.name, "Struct")
  end

  for decl in enums
    if decl.type_parameters.size == 0
      kinds = kinds.put(decl.name, "Enum")
    end
  end

  table = builtin
  generic: Map[String, Ast.StructDecl] = {}
  for decl in structs
    if decl.type_parameters.size > 0
      generic = generic.put(decl.name, decl)
    else
      fields = struct_fields(decl, kinds, {})
      if fields.some?
        table = table.put(decl.name, fields.unwrap!)
      end
    end
  end

  for decl in enums
    types: List[Types.Type] = []
    complete = decl.type_parameters.size == 0
    for variant in decl.variants
      for payload in variant.payload_types
        found = json_field_inner(payload, kinds, {})
        case found
          some(type) -> types = types.push(type)
          none -> complete = false
        end
      end
    end

    if complete
      table = table.put(decl.name, types)
    end
  end

  pending: List[Types.Type] = type_targets.flat_map(&instances_in)
  for types in table.values
    pending = pending.concat(types.flat_map(&instances_in))
  end

  instances: Map[String, Types.Type] = {}
  at = 0
  while at < pending.size
    type = pending[at]
    at += 1
    key = json_list_name(type)
    next if instances.has_key?(key)

    instances = instances.put(key, type)
    decl = generic.get(Types.name(type))
    next if decl.none? or depth(type) > MAX_INSTANCE_DEPTH

    parameters = decl.unwrap!.type_parameters
    next if parameters.size != Types.args(type).size

    substitutions: Map[String, Types.Type] = {}
    for index in 0...parameters.size
      substitutions = substitutions.put(parameters[index], Types.args(type)[index])
    end

    fields = struct_fields(decl.unwrap!, kinds, substitutions)
    if fields.some?
      table = table.put(key, fields.unwrap!)
      pending = pending.concat(fields.unwrap!.flat_map(&instances_in))
    end
  end

  size = table.size + 1
  while table.size < size
    size = table.size
    kept: Map[String, List[Types.Type]] = {}
    for name in table.keys
      if references_known?(table[name], table)
        kept = kept.put(name, table[name])
      end
    end

    table = kept
  end

  Found(table: with_reachable_enums(table, kinds, type_names), instances: instances)
end

# The field types of a struct as JSON.decode builds them, with substitutions for the parameters of a generic one, or
# none when a field cannot be built.
def struct_fields(
  decl: Ast.StructDecl,
  kinds: Map[String, String],
  substitutions: Map[String, Types.Type],
) -> Optional[List[Types.Type]]
  types: List[Types.Type] = []
  for field in decl.fields
    found = field_type(field.type, kinds, substitutions)
    return none if found.none?

    types = types.push(found.unwrap!)
  end

  some(types)
end

# The instances of generic structs in a field type, under any List, Map, Optional or JSON.Field around it: their own
# arguments count only through their fields.
def instances_in(type: Types.Type) -> List[Types.Type]
  case type
    Types.Type.Struct(_, args) ->
      return [] if args.size == 0

      [type]
    Types.Type.List(item) -> instances_in(item)
    Types.Type.Optional(item) -> instances_in(item)
    Types.Type.Map(_, value) -> instances_in(value)
    Types.Type.Enum(name, args) ->
      return instances_in(args[0]) if name == "JSON.Field"

      []
    _ -> []
  end
end

# The levels of a type: 0 for one without arguments or items, 1 more for each List, Map, Optional and argument list
# around it (Box[List[Int]] is 2), as check_types.agc type_depth counts.
def depth(type: Types.Type) -> Int
  case type
    Types.Type.Struct(_, args) -> deepest(args)
    Types.Type.Enum(_, args) -> deepest(args)
    Types.Type.List(item) -> depth(item) + 1
    Types.Type.Optional(item) -> depth(item) + 1
    Types.Type.Map(_, value) -> depth(value) + 1
    _ -> 0
  end
end

def deepest(types: List[Types.Type]) -> Int = types.map(&depth).max.map(->(found) { found + 1 }).unwrap_or(0)

# The table with the structs and the enums that a struct or a name of type_names reaches: an enum nothing JSON
# can build
# mentions is left out, so a program that decodes a Person does not carry every enum it declares.
def with_reachable_enums(
  table: Map[String, List[Types.Type]],
  kinds: Map[String, String],
  type_names: List[String],
) -> Map[String, List[Types.Type]]
  pending = type_names.filter do |name: String| table.has_key?(name) end
  for name in table.keys
    if kinds.get(name, "") == "Struct"
      pending = pending.push(name)
    end
  end

  reached: Set[String] = Set.new(pending)
  at = 0
  while at < pending.size
    for type in table[pending[at]]
      for name in struct_names_in(type)
        if !reached.include?(name)
          reached = reached.add(name)
          pending = pending.push(name)
        end
      end
    end

    at += 1
  end

  kept: Map[String, List[Types.Type]] = {}
  for name in table.keys
    if reached.include?(name)
      kept = kept.put(name, table[name])
    end
  end

  kept
end

# True when every struct a list of field types names is in the table.
def references_known?(types: List[Types.Type], table: Map[String, List[Types.Type]]) -> Bool
  for type in types
    for name in struct_names_in(type)
      return false if !table.has_key?(name)
    end
  end

  true
end

# The struct or enum a field type is made of, under any List, Map, Optional or JSON.Field around it.
def struct_names_in(type: Types.Type) -> List[String]
  case type
    Types.Type.Struct(_, args) ->
      return [json_list_name(type)] if args.size > 0

      [Types.name(type)]
    Types.Type.List(item) -> struct_names_in(item)
    Types.Type.Optional(item) -> struct_names_in(item)
    Types.Type.Map(_, value) -> struct_names_in(value)
    Types.Type.Enum(name, args) ->
      return struct_names_in(args[0]) if name == "JSON.Field"

      [name]
    _ -> []
  end
end

# True for a JSON.Field field type.
def json_field?(type: Types.Type) -> Bool = Types.is?(type, "Enum") and Types.name(type) == "JSON.Field"

# True when an Optional sits in a field type, under any List, Map or JSON.Field around it.
def optional_in?(type: Types.Type) -> Bool
  case type
    Types.Type.Optional(_) -> true
    Types.Type.List(item) -> optional_in?(item)
    Types.Type.Map(_, value) -> optional_in?(value)
    Types.Type.Enum(name, args) -> name == "JSON.Field" and optional_in?(args[0])
    _ -> false
  end
end

# The type of a struct field as JSON.decode builds it, or `none` when it cannot: a JSON.Field of a JSON type other than
# an Optional, or a JSON type. JSON.Field is only allowed here, as the direct type of the field.
# substitutions gives the type of each parameter of a generic struct.
def field_type(
  ref: Ast.TypeRef,
  kinds: Map[String, String],
  substitutions: Map[String, Types.Type],
) -> Optional[Types.Type]
  if ref.name != "JSON.Field" or ref.args.size != 1
    return json_field_inner(ref, kinds, substitutions)
  elsif ref.args[0].name == "Optional"
    return none
  end

  value = json_field_inner(ref.args[0], kinds, substitutions)
  case value
    some(type) -> some(Types.Type.Enum("JSON.Field", [type]))
    none -> none
  end
end

# The type of a JSON value as JSON.decode builds it inside a field (the whole field type, or T of a JSON.Field[T]) or a
# payload, or `none` when it cannot. kinds maps the names of the structs and enums to "Struct" or "Enum".
def json_field_inner(
  ref: Ast.TypeRef,
  kinds: Map[String, String],
  substitutions: Map[String, Types.Type],
) -> Optional[Types.Type]
  args = ref.args
  if args.size == 0 and substitutions.has_key?(ref.name)
    return some(substitutions[ref.name])
  elsif args.size == 0 and (ref.name == "Int" or ref.name == "Int64")
    return some(Types.Type.Int)
  elsif args.size == 0 and (ref.name == "Float" or ref.name == "Float64")
    return some(Types.Type.Float)
  elsif args.size == 0 and Types.NARROW_INTS.has_key?(ref.name)
    return some(Types.narrow_int(ref.name))
  elsif args.size == 0 and ref.name == "Float32"
    return some(Types.Type.Float32)
  elsif args.size == 0 and ref.name == "Bool"
    return some(Types.Type.Bool)
  elsif args.size == 0 and ref.name == "String"
    return some(Types.Type.String)
  elsif ref.name == "List" and args.size == 1
    item = json_field_inner(args[0], kinds, substitutions)
    case item
      some(type) -> return some(Types.Type.List(type))
      none -> return none
    end
  elsif ref.name == "Optional" and args.size == 1
    item = json_field_inner(args[0], kinds, substitutions)
    case item
      some(type) -> return some(Types.Type.Optional(type))
      none -> return none
    end
  elsif ref.name == "Map" and args.size == 2 and args[0].name == "String" and args[0].args.size == 0
    value = json_field_inner(args[1], kinds, substitutions)
    case value
      some(type) -> return some(Types.Type.Map(Types.Type.String, type))
      none -> return none
    end
  elsif args.size == 0 and kinds.get(ref.name, "") == "Struct"
    return some(Types.Type.Struct(ref.name, []))
  elsif kinds.get(ref.name, "") == "Struct"
    found: List[Types.Type] = []
    for arg in args
      converted = field_type(arg, kinds, substitutions)
      return none if converted.none?

      found = found.push(converted.unwrap!)
    end

    return some(Types.Type.Struct(ref.name, found))
  elsif args.size == 0 and kinds.get(ref.name, "") == "Enum"
    return some(Types.Type.Enum(ref.name, []))
  end

  none
end
