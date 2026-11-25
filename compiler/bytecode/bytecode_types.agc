## The Types and Decodable sections of the .agcb (docs/vm/03-ir-and-bytecode.md 4.6): the field types of the structs
## that JSON.decode may build, as a table of types in which a List, a Map from String, a JSON.Field, an Optional, a
## struct and an enum name the entry of their item, and for each such struct the entries of its fields. The enums that
## JSON.decode may build go in a last section of the file (4.6), with the entries of the payloads of their variants.
##
## Recursion: type_id takes 1 VM frame for each level of List and Map in a field type. The parser stops a written type
## at 1,000 levels, and the writer stops at 1,024 (BYTECODE-LIMIT), so the writer stays under 1,100 frames here.

import Ir from "../lower/ir"
import Types from "../syntax/types"
import Wire from "bytecode_bytes"
import Failure from "bytecode_failure"
import Pool from "bytecode_pool"
import {MAX_TYPE_DEPTH, MAX_U16} from "bytecode_tables"

## The sections: the type table (entries in the order they were first needed), and the records of the Decodable
## section, of the decodable enums, which the writer puts last in the file, and of the struct instances.
struct Section
  types: Pool.Pool
  decodable: Wire.Prefix
  enums: Wire.Prefix
  instances: Wire.Prefix
end

## Builds the sections for the structs and enums of the program. struct_index and enum_index map a name to its place in
## the table. The type table starts from `types`, the table of an earlier program that this one extends, and each
## section from the records of that program (`held`), so only the entries after them are written.
def build(
  program: Ir.Program,
  struct_index: Map[String, Int],
  enum_index: Map[String, Int],
  types: Pool.Pool,
  held: Section,
) -> Result[Section]
  pool = types
  chunks = held.decodable.chunks
  count = held.decodable.records
  index = held.decodable.count
  fresh_types: List[Types.Type] = []
  for entry in program.structs.drop(index)
    if entry.decodable
      chunks = Wire.add(chunks, Wire.u32(index))
      chunks = Wire.add_text(chunks, entry.name)
      for type in entry.types
        found = try type_id(program, struct_index, enum_index, pool, type)
        pool = found.pool
        chunks = Wire.add(chunks, Wire.u32(found.id))
      end

      fresh_types = fresh_types.concat(entry.types)
      count += 1
    end

    index += 1
  end

  enum_chunks = held.enums.chunks
  enum_count = held.enums.records
  index = held.enums.count
  for entry in program.enums.drop(index)
    if entry.decodable
      enum_chunks = Wire.add(enum_chunks, Wire.u32(index))
      enum_chunks = Wire.add_text(enum_chunks, entry.name)
      for type in entry.types
        found = try type_id(program, struct_index, enum_index, pool, type)
        pool = found.pool
        enum_chunks = Wire.add(enum_chunks, Wire.u32(found.id))
      end

      fresh_types = fresh_types.concat(entry.types)
      enum_count += 1
    end

    index += 1
  end

  instance_chunks = held.instances.chunks
  for entry in program.instances.drop(held.instances.count)
    instance_chunks = Wire.add(instance_chunks, Wire.u32(struct_index[entry.struct_name]))
    instance_chunks = Wire.add_text(instance_chunks, entry.name)
    for type in entry.types
      found = try type_id(program, struct_index, enum_index, pool, type)
      pool = found.pool
      instance_chunks = Wire.add(instance_chunks, Wire.u32(found.id))
    end

    fresh_types = fresh_types.concat(entry.types)
  end

  return error(Failure.limit(program, 0, "JSON field types", program.span)) if pool.count > MAX_U16

  for type in fresh_types
    if nesting(type) > MAX_TYPE_DEPTH
      what = "nested List and Map levels in a JSON field type"
      return error(Failure.limit(program, 0, what, program.span))
    end
  end

  ok(
    Section(
      types: pool,
      decodable: Wire.Prefix(count: program.structs.size, records: count, chunks: chunks),
      enums: Wire.Prefix(count: program.enums.size, records: enum_count, chunks: enum_chunks),
      instances: Wire.Prefix(count: program.instances.size, records: program.instances.size, chunks: instance_chunks),
    ),
  )
end

## The entry of the JSON.decode or JSON.schema target `type` (Ir.Imm.Type), added to `pool` when it is new.
def target(
  program: Ir.Program,
  struct_index: Map[String, Int],
  enum_index: Map[String, Int],
  pool: Pool.Pool,
  type: Types.Type,
) -> Result[Pool.Interned]
  if !Types.is?(type, "Struct") and !Types.is?(type, "Enum")
    return error(unsupported(program, "a JSON.decode target of #{Types.tag(type)}"))
  end

  type_id(program, struct_index, enum_index, pool, type)
end

private

# The entry of a type, added after the entries of the types it is made of. An entry is its tag (0 Int, 1 Float, 2 Bool,
# 3 String, 4 List, 5 Map from String, 6 struct, 7 JSON.Field, 8 Optional, 9 enum, 10 struct instance, 11 to 16 Int8,
# Int16, Int32, UInt8, UInt16 and UInt32, 17 UInt64, 18 Float32) and, for tags 4 to 10, the number of the item
# type, the
# struct, the type inside the JSON.Field or the Optional, the enum, or the instance.
def type_id(
  program: Ir.Program,
  struct_index: Map[String, Int],
  enum_index: Map[String, Int],
  pool: Pool.Pool,
  type: Types.Type,
) -> Result[Pool.Interned]
  return instance_id(program, pool, type) if Types.is?(type, "Struct") and Types.args(type).size > 0

  case type
    Types.Type.Int -> ok(Pool.intern(pool, "0", [0]))
    Types.Type.Float -> ok(Pool.intern(pool, "1", [1]))
    Types.Type.Bool -> ok(Pool.intern(pool, "2", [2]))
    Types.Type.String -> ok(Pool.intern(pool, "3", [3]))
    Types.Type.Int8 -> ok(Pool.intern(pool, "11", [11]))
    Types.Type.Int16 -> ok(Pool.intern(pool, "12", [12]))
    Types.Type.Int32 -> ok(Pool.intern(pool, "13", [13]))
    Types.Type.UInt8 -> ok(Pool.intern(pool, "14", [14]))
    Types.Type.UInt16 -> ok(Pool.intern(pool, "15", [15]))
    Types.Type.UInt32 -> ok(Pool.intern(pool, "16", [16]))
    Types.Type.UInt64 -> ok(Pool.intern(pool, "17", [17]))
    Types.Type.Float32 -> ok(Pool.intern(pool, "18", [18]))
    Types.Type.List(item) ->
      inner = try type_id(program, struct_index, enum_index, pool, item)
      ok(entry_of(inner.pool, 4, inner.id))
    Types.Type.Map(key, value) ->
      if !Types.is?(key, "String")
        return error(unsupported(program, "a Map with a key that is not a String in a JSON field type"))
      end

      inner = try type_id(program, struct_index, enum_index, pool, value)
      ok(entry_of(inner.pool, 5, inner.id))
    Types.Type.Enum(name, args) ->
      if name == "JSON.Field" and args.size == 1
        inner = try type_id(program, struct_index, enum_index, pool, args[0])
        return ok(entry_of(inner.pool, 7, inner.id))
      end

      if args.size != 0 or !enum_index.has_key?(name)
        return error(unsupported(program, "the enum #{name} in a JSON field type is not in the table"))
      end

      ok(entry_of(pool, 9, enum_index[name]))
    Types.Type.Optional(item) ->
      inner = try type_id(program, struct_index, enum_index, pool, item)
      ok(entry_of(inner.pool, 8, inner.id))
    Types.Type.Struct(name, _) ->
      if !struct_index.has_key?(name)
        return error(unsupported(program, "the struct #{name} in a JSON field type is not in the table"))
      end

      ok(entry_of(pool, 6, struct_index[name]))
    _ -> error(unsupported(program, "a JSON field type of #{Types.tag(type)}"))
  end
end

# The entry of an instance of a generic struct: tag 10 and its place in program.instances, found by its type.
def instance_id(program: Ir.Program, pool: Pool.Pool, type: Types.Type) -> Result[Pool.Interned]
  name = Types.json_name(type)
  at = 0
  for entry in program.instances
    return ok(entry_of(pool, 10, at)) if Types.json_name(entry.type) == name

    at += 1
  end

  error(unsupported(program, "the struct instance #{Types.to_text(type)} in a JSON field type is not in the table"))
end

def entry_of(pool: Pool.Pool, tag: Int, number: Int) -> Pool.Interned
  Pool.intern(pool, "#{tag}:#{number}", [tag].concat(Wire.u32(number)))
end

def unsupported(program: Ir.Program, message: String) -> String = Failure.internal(program, message)

# The levels of List, Map, JSON.Field and Optional around a type.
def nesting(type: Types.Type) -> Int
  case type
    Types.Type.List(item) -> 1 + nesting(item)
    Types.Type.Map(_, item) -> 1 + nesting(item)
    Types.Type.Enum(name, args) ->
      return 1 + nesting(args[0]) if name == "JSON.Field"

      0
    Types.Type.Optional(item) -> 1 + nesting(item)
    _ -> 0
  end
end
