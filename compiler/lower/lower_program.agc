## The struct and enum tables of the lowered program The program's structs come first, then the builtin records it
## uses, each in the order of the catalog; enums likewise, and their variants are numbered in table order.

import Ast from "../syntax/ast"
import Model from "../catalog/builtin_model"
import Ir from "ir"
import State from "lower_state"
import {BUILTIN_STRUCTS, STRUCT_NEEDS} from "lower_tables"
import Types from "../syntax/types"
import {ENUMS, RECORDS} from "../catalog/builtins"

## The tables, and what the lowering looks up in them. user_types maps each name in the tables to "Struct" or "Enum",
## structs gives the index and the fields of a struct by name, variants the id of "Enum.Variant", and json_structs the
## structs JSON.decode may build.
export struct Tables
  structs: List[Ir.StructDef]
  enums: List[Ir.EnumDef]
  user_types: Map[String, String]
  infos: Map[String, State.StructInfo]
  variants: Map[String, Int]
  json_structs: Set[String]
end

## Builds the tables. decls are all the declarations of the program in order. used are the watched type names that the
## program writes or whose types some expression has (a builtin record or enum is in the tables only then). type_value
## says that a function uses a type name as a value, which is when the user structs that JSON can build are looked for.
export def build(decls: List[Ast.Decl], used: Set[String], type_value: Bool) -> Tables
  struct_decls: List[Ast.StructDecl] = []
  enum_decls: List[Ast.EnumDecl] = []
  for decl in decls
    case decl
      Ast.Decl.Struct(node) -> struct_decls = struct_decls.push(node)
      Ast.Decl.Enum(node) -> enum_decls = enum_decls.push(node)
      _ -> struct_decls = struct_decls
    end
  end
  builtin_types = builtin_decodable()
  decodable = user_decodable(struct_decls, builtin_types, type_value)
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
  structs = structs.concat(builtin_structs(used, builtin_types))
  enums: List[Ir.EnumDef] = []
  for decl in enum_decls
    variants = decl.variants.map do |variant: Ast.EnumVariant|
      Ir.VariantDef(name: variant.name, size: variant.payload_types.size)
    end
    enums = enums.push(Ir.EnumDef(name: decl.name, variants: variants))
  end
  for name in ENUMS.keys
    if used.include?(name)
      variants = ENUMS[name].variants.map do |variant: Model.Variant|
        Ir.VariantDef(name: variant.name, size: variant.payload.size)
      end
      enums = enums.push(Ir.EnumDef(name: name, variants: variants))
    end
  end
  return index(structs, enums)
end

# The lookups over the finished tables.
def index(structs: List[Ir.StructDef], enums: List[Ir.EnumDef]) -> Tables
  user_types: Map[String, String] = {}
  infos: Map[String, State.StructInfo] = {}
  json_structs: Set[String] = Set.new([])
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
      json_structs = json_structs.add(entry.name)
    end
    at += 1
  end
  variants: Map[String, Int] = {}
  id = 0
  for entry in enums
    user_types = user_types.put(entry.name, "Enum")
    for variant in entry.variants
      variants = variants.put("#{entry.name}.#{variant.name}", id)
      id += 1
    end
  end
  return Tables(
    structs: structs,
    enums: enums,
    user_types: user_types,
    infos: infos,
    variants: variants,
    json_structs: json_structs,
  )
end

# The field types of the builtin records JSON.decode can build: all but those with an enum or channel field.
def builtin_decodable() -> Map[String, List[Types.Type]]
  found: Map[String, List[Types.Type]] = {}
  for name in BUILTIN_STRUCTS
    types = RECORDS[name].map do |field: Model.Named| field.type end
    if !types.any? do |type: Types.Type| Types.is?(type, "Enum") or Types.is?(type, "Channel") end
      found = found.put(name, types)
    end
  end
  return found
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
  return found
end

# The user structs JSON.decode can build, with their field types: every field is an Int, Float, Bool or String, or a
# List or a Map from String of such a type or of a struct that can be built itself. Only looked for when some function
# uses a type name as a value.
def user_decodable(
  structs: List[Ast.StructDecl], builtin: Map[String, List[Types.Type]], type_value: Bool
) -> Map[String, List[Types.Type]]
  if !type_value
    return {}
  end
  names: Set[String] = Set.new(BUILTIN_STRUCTS)
  for decl in structs
    names = names.add(decl.name)
  end
  table = builtin
  for decl in structs
    types: List[Types.Type] = []
    complete = true
    for field in decl.fields
      found = json_field_type(field.type, names)
      case found
        Ast.Optional.Present(type) -> types = types.push(type)
        Ast.Optional.Absent -> complete = false
      end
    end
    if complete
      table = table.put(decl.name, types)
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
  return table
end

# True when every struct a list of field types names is in the table.
def references_known?(types: List[Types.Type], table: Map[String, List[Types.Type]]) -> Bool
  for type in types
    for name in struct_names_in(type)
      if !table.has_key?(name)
        return false
      end
    end
  end
  return true
end

# The struct a field type is made of, under any List or Map around it.
def struct_names_in(type: Types.Type) -> List[String]
  case type
    Types.Type.Struct(name) -> return [name]
    Types.Type.List(item) -> return struct_names_in(item)
    Types.Type.Map(key, value) -> return struct_names_in(value)
    _ -> return []
  end
end

# The type of a struct field as JSON.decode builds it, or Absent when it cannot.
def json_field_type(ref: Ast.TypeRef, names: Set[String]) -> Ast.Optional[Types.Type]
  args = ref.args
  if args.size == 0 and ref.name == "Int"
    return Ast.Optional.Present(Types.Type.Int)
  elsif args.size == 0 and ref.name == "Float"
    return Ast.Optional.Present(Types.Type.Float)
  elsif args.size == 0 and ref.name == "Bool"
    return Ast.Optional.Present(Types.Type.Bool)
  elsif args.size == 0 and ref.name == "String"
    return Ast.Optional.Present(Types.Type.String)
  elsif ref.name == "List" and args.size == 1
    item = json_field_type(args[0], names)
    case item
      Ast.Optional.Present(type) -> return Ast.Optional.Present(Types.Type.List(type))
      Ast.Optional.Absent -> return Ast.Optional.Absent
    end
  elsif ref.name == "Map" and args.size == 2 and args[0].name == "String" and args[0].args.size == 0
    value = json_field_type(args[1], names)
    case value
      Ast.Optional.Present(type) -> return Ast.Optional.Present(Types.Type.Map(Types.Type.String, type))
      Ast.Optional.Absent -> return Ast.Optional.Absent
    end
  elsif args.size == 0 and names.include?(ref.name)
    return Ast.Optional.Present(Types.Type.Struct(ref.name))
  end
  return Ast.Optional.Absent
end
