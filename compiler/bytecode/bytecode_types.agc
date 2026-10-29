## The Types and Decodable sections of the .agcb (docs/vm/03-ir-and-bytecode.md 4.6): the field types of the structs
## that JSON.decode may build, as a table of types in which a List, a Map from String, a JsonField and a struct name
## the entry of their item, and for each such struct the entries of its fields.
##
## Recursion: type_id takes 1 VM frame for each level of List and Map in a field type. The parser stops a written type
## at 1,000 levels, and the writer stops at 1,024 (BYTECODE-LIMIT), so the writer stays under 1,100 frames here.

import Ir from "../lower/ir"
import Types from "../syntax/types"
import Wire from "bytecode_bytes"
import Failure from "bytecode_failure"
import Pool from "bytecode_pool"
import {MAX_TYPE_DEPTH, MAX_U16} from "bytecode_tables"

## The two sections: the type table (entries in the order they were first needed) and the bytes of the Decodable
## section after its count, with the count.
export struct Section
  types: Pool.Pool
  decodable: List[List[Int]]
  decodable_count: Int
end

## Builds the sections for the structs of the program. struct_index maps a struct name to its place in the table.
export def build(program: Ir.Program, struct_index: Map[String, Int]) -> Result[Section]
  pool = Pool.empty()
  chunks = Wire.start()
  count = 0
  index = 0
  for entry in program.structs
    if entry.decodable
      chunks = Wire.add(chunks, Wire.u32(index))
      chunks = Wire.add(chunks, Wire.string(entry.name))
      for type in entry.types
        found = try type_id(program, struct_index, pool, type)
        pool = found.pool
        chunks = Wire.add(chunks, Wire.u32(found.id))
      end

      count += 1
    end

    index += 1
  end

  if pool.count > MAX_U16
    return error(Failure.limit(program, 0, "JSON field types", program.span))
  end

  for entry in program.structs
    if entry.decodable
      for type in entry.types
        if nesting(type) > MAX_TYPE_DEPTH
          what = "nested List and Map levels in a JSON field type"
          return error(Failure.limit(program, 0, what, program.span))
        end
      end
    end
  end

  return ok(Section(types: pool, decodable: chunks, decodable_count: count))
end

# The entry of a type, added after the entries of the types it is made of. An entry is its tag (0 Int, 1 Float, 2 Bool,
# 3 String, 4 List, 5 Map from String, 6 struct, 7 JsonField) and, for the last four, the number of the item type, the
# struct or the type inside the JsonField.
def type_id(
  program: Ir.Program, struct_index: Map[String, Int], pool: Pool.Pool, type: Types.Type
) -> Result[Pool.Interned]
  case type
    Types.Type.Int -> return ok(Pool.intern(pool, "0", [0]))
    Types.Type.Float -> return ok(Pool.intern(pool, "1", [1]))
    Types.Type.Bool -> return ok(Pool.intern(pool, "2", [2]))
    Types.Type.String -> return ok(Pool.intern(pool, "3", [3]))
    Types.Type.List(item) ->
      inner = try type_id(program, struct_index, pool, item)
      return ok(entry_of(inner.pool, 4, inner.id))
    Types.Type.Map(key, value) ->
      if !Types.is?(key, "String")
        return error(unsupported(program, "a Map with a key that is not a String in a JSON field type"))
      end

      inner = try type_id(program, struct_index, pool, value)
      return ok(entry_of(inner.pool, 5, inner.id))
    Types.Type.Enum(name, args) ->
      if name != "JsonField" or args.size != 1
        return error(unsupported(program, "the enum #{name} in a JSON field type"))
      end

      inner = try type_id(program, struct_index, pool, args[0])
      return ok(entry_of(inner.pool, 7, inner.id))
    Types.Type.Struct(name, args) ->
      if !struct_index.has_key?(name)
        return error(unsupported(program, "the struct #{name} in a JSON field type is not in the table"))
      end

      return ok(entry_of(pool, 6, struct_index[name]))
    _ -> return error(unsupported(program, "a JSON field type of #{Types.tag(type)}"))
  end
end

def entry_of(pool: Pool.Pool, tag: Int, number: Int) -> Pool.Interned
  return Pool.intern(pool, "#{tag}:#{number}", [tag].concat(Wire.u32(number)))
end

def unsupported(program: Ir.Program, message: String) -> String
  return Failure.internal(program, message)
end

# The levels of List and Map around a type.
def nesting(type: Types.Type) -> Int
  case type
    Types.Type.List(item) -> return 1 + nesting(item)
    Types.Type.Map(key, item) -> return 1 + nesting(item)
    Types.Type.Enum(name, args) -> return 1 + nesting(args[0])
    _ -> return 0
  end
end
