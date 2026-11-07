## The canonical forms of a function of an `extern module "NAME"` block (#1149): the signature text and the shape of
## each user type that crosses, which the VM compares byte for byte with the module's table (vm/native_module.c). The
## lowering writes them into the signature of the call (lower_native.agc) and `std/analysis` lists them for code
## generators (analysis/native_modules.agc), both from `of_function`, so a generator can never differ from the
## compiler.
##
## They are built from the types the checker recorded for the written ones (check_native.agc), by node id: aliases
## expanded, user types by their bare names. This module needs no lowering state, so the core of `std/analysis` can
## carry it.

import Ast from "../syntax/ast"
import Types from "../syntax/types"

## The tags of `Crossing.tag`, as `Types.is?` names the kinds of type.
export STRUCT = "Struct"
export ENUM = "Enum"
export RESOURCE = "Opaque"

## The version of the C API of native modules (AN_API_MAJOR of vm/agentica_native.h), and the least minor version that
## has what a block uses: 1.0 has functions of scalars and collections, 1.1 adds the program's structs and enums, 1.2
## the module's resources. tests/test_std_analysis.py checks them against the header.
export API_MAJOR = 1
export API_MINOR_TYPES = 1
export API_MINOR_RESOURCES = 2

## One field of a struct or variant of an enum that crosses: its name and its canonical types, the field's type (one)
## or the payload of the variant.
export struct Member
  name: String
  types: List[String]
end

## A type the signature reaches besides the scalars and the collections: a struct or an enum of the program, with its
## members and the shape the module's table must have for its bare name ("name: Type, ..." for a struct, "Variant |
## Variant(Type, ...)" for an enum), or a resource of the block. `name` is the linked name; a resource has no members
## and an empty shape.
export struct Crossing
  name: String
  tag: String
  members: List[Member]
  shape: String
end

## The canonical signature of one function: the type of each parameter and of the result, `text` ("(Int, String) ->
## List[Int]", the form the module's function table has) and the types it reaches, each once, in the order the walk
## meets them (the parameters first, then the result, each type before the types of its fields and payloads).
## `from_params` and `from_result` are the linked names of the crossings reached from the parameters alone and from the
## result alone, in the same order, through the fields and payloads too: a type that only the result reaches is made
## by the module and never read, and one that only a parameter reaches is read and never made.
export struct Signature
  params: List[String]
  result: String
  text: String
  crossings: List[Crossing]
  from_params: List[String]
  from_result: List[String]
end

## The signature of `function`, a function of a native module block. `types` are the types of the checker by node id,
## and `structs` and `enums` the declarations of the program by linked name. The error is a message for a type the
## checker recorded nothing for, which the caller turns into its own internal failure.
export def of_function(
  types: List[Types.Type],
  function: Ast.FunctionDecl,
  structs: Map[String, Ast.StructDecl],
  enums: Map[String, Ast.EnumDecl],
) -> Result[Signature]
  params: List[String] = []
  written: List[Types.Type] = []
  for param in function.params
    type = try recorded(types, param.type)
    params = params.push(Types.to_text(type))
    written = written.push(type)
  end

  result = try recorded(types, function.result)
  crossings = try reach(types, written.push(result), structs, enums)
  inputs = try reach(types, written, structs, enums)
  outputs = try reach(types, [result], structs, enums)
  text = "(#{params.join(", ")}) -> #{Types.to_text(result)}"
  return ok(
    Signature(
      params: params,
      result: Types.to_text(result),
      text: text,
      crossings: crossings,
      from_params: inputs.map do |crossing: Crossing| crossing.name end,
      from_result: outputs.map do |crossing: Crossing| crossing.name end,
    ),
  )
end

# The crossings that the types `roots` reach, each once, in the order the walk meets them. The walk is a list, not a
# recursion, so a recursive type ends.
def reach(
  types: List[Types.Type],
  roots: List[Types.Type],
  structs: Map[String, Ast.StructDecl],
  enums: Map[String, Ast.EnumDecl],
) -> Result[List[Crossing]]
  pending = roots
  crossings: List[Crossing] = []
  seen: Set[String] = Set.new([])
  at = 0
  while at < pending.size
    type = pending[at]
    at += 1
    name = Types.name(type)
    if seen.include?(name)
      next
    end

    if Types.is?(type, STRUCT)
      seen = seen.add(name)
      fields: List[Member] = []
      for field in structs[name].fields
        field_type = try recorded(types, field.type)
        fields = fields.push(Member(name: field.name, types: [Types.to_text(field_type)]))
        pending = pending.push(field_type)
      end

      texts = fields.map do |member: Member| "#{member.name}: #{member.types[0]}" end
      crossings = crossings.push(Crossing(name: name, tag: STRUCT, members: fields, shape: texts.join(", ")))
    elsif Types.is?(type, ENUM)
      seen = seen.add(name)
      cases: List[Member] = []
      for variant in enums[name].variants
        payload: List[String] = []
        for ref in variant.payload_types
          payload_type = try recorded(types, ref)
          payload = payload.push(Types.to_text(payload_type))
          pending = pending.push(payload_type)
        end

        cases = cases.push(Member(name: variant.name, types: payload))
      end

      variants = cases.map do |member: Member| variant_text(member) end
      crossings = crossings.push(Crossing(name: name, tag: ENUM, members: cases, shape: variants.join(" | ")))
    elsif Types.is?(type, RESOURCE)
      # The checker lets only a resource of the module block through as an opaque type.
      seen = seen.add(name)
      crossings = crossings.push(Crossing(name: name, tag: RESOURCE, members: [], shape: ""))
    else
      pending = pending.concat(inner_types(type))
    end
  end

  return ok(crossings)
end

# A variant as the shape writes it: its name, then its payload in parentheses when it has one.
def variant_text(member: Member) -> String
  if member.types.size == 0
    return member.name
  end

  return "#{member.name}(#{member.types.join(", ")})"
end

# The type the checker recorded for a written type, or the message that it recorded none.
def recorded(types: List[Types.Type], ref: Ast.TypeRef) -> Result[Types.Type]
  if ref.id < 0 or ref.id >= types.size or Types.unknown?(types[ref.id])
    return error("the checker recorded no type for #{ref.name}")
  end

  return ok(types[ref.id])
end

# The types inside a List, Optional, Result or Map, which crossing types are besides the scalars and user types.
def inner_types(type: Types.Type) -> List[Types.Type]
  if Types.is?(type, "Map")
    return [Types.key(type), Types.value(type)]
  end

  if Types.is?(type, "List") or Types.is?(type, "Optional") or Types.is?(type, "Result")
    return [Types.item(type)]
  end

  return []
end
