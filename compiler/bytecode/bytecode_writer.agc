## The bytecode writer: the .agcb bytes of a lowered program.
## The file is, in this order, the header, the sources, the spans, the constants, the structs, the JSON field types,
## the Decodable structs, the enums, the struct updates, the Globals count, the builtins, the functions, the entry and,
## when some enum can be decoded, the Decodable enums, the Struct instances and the Field defaults
## (docs/vm/03-ir-and-bytecode.md 4.6).
## tests/test_frontend_bytecode.py compares them with frozen goldens.
##
## The functions are walked first, because they decide the entries of the constant, update, builtin and span tables,
## which come before them in the file. The output is a list of chunks that is joined once at the end.
##
## Recursion: only the JSON field types recurse (bytecode_types.agc, 1 VM frame for each level, at most 1,024 levels).

import Problems from "../diagnostics/problem"
import Ir from "../lower/ir"
import Types from "../syntax/types"
import Wire from "bytecode_bytes"
import Failure from "bytecode_failure"
import Function from "bytecode_function"
import Pool from "bytecode_pool"
import Spans from "bytecode_spans"
import {FORMAT_VERSION, MAX_U16} from "bytecode_tables"
import JsonTypes from "bytecode_types"

## The result of writing: the bytes of the file, or the first problem (BYTECODE-LIMIT or BYTECODE-INTERNAL).
enum Written
  Done(Bytes)
  Failed(Problems.Problem)
end

## What `write_over` gives: the bytes or the first problem, and the tables after the program (the seed when it failed).
struct Over
  written: Written
  tables: Function.Tables
end

## Writes the program. version is the Agentica version that the header names; the VM loads the file only when it is
## its own, so an empty one is BYTECODE-INTERNAL.
def write(program: Ir.Program, version: String) -> Written = write_over(program, version, no_tables()).written

## The tables of a program that has none yet.
def no_tables() -> Function.Tables
  Function.Tables(constants: Pool.empty(), updates: Pool.empty(), builtins: Pool.empty(), spans: Pool.empty())
end

## Writes the program as `write` does, with the constant, struct update, builtin and span tables starting from `seed`,
## the tables of an earlier program whose functions this one starts with: each entry of those tables keeps its number,
## as the session of `agentica repl` needs (compiler/repl/).
def write_over(program: Ir.Program, version: String, seed: Function.Tables) -> Over
  if version == ""
    return Over(
      written: Written.Failed(Problems.unpack(Failure.internal(program, "the Agentica version is empty"))),
      tables: seed,
    )
  end

  result = build(program, version, seed)
  return Over(written: Written.Done(result.unwrap!.bytes), tables: result.unwrap!.tables) if result.ok?

  Over(written: Written.Failed(Problems.unpack(result.message)), tables: seed)
end

private

# The bytes of a program and the tables after it.
struct Built
  bytes: Bytes
  tables: Function.Tables
end

# The Field defaults section and the constant table with its constants.
struct Defaults
  chunks: Wire.Chunks
  count: Int
  constants: Pool.Pool
end

def build(program: Ir.Program, version: String, seed: Function.Tables) -> Result[Built]
  try check_limits(program)
  struct_index: Map[String, Int] = {}
  at = 0
  for entry in program.structs
    struct_index = struct_index.put(entry.name, at)
    at += 1
  end

  enum_index: Map[String, Int] = {}
  at = 0
  for entry in program.enums
    enum_index = enum_index.put(entry.name, at)
    at += 1
  end

  json = try JsonTypes.build(program, struct_index, enum_index)
  # The span of the program is the first run of the span table.
  tables = seed.with(spans: Spans.intern_one(seed.spans, 0, program.span).pool)
  functions = Wire.start()
  for function in program.functions
    encoded = try Function.encode(program, tables, function)
    tables = encoded.tables
    functions = Wire.add_all(functions, encoded.parts)
  end

  found = field_defaults(program, tables.constants)
  tables = tables.with(constants: found.constants)
  out = (
    header(version)
    |> sources(program)
    |> pool_section(tables.spans)
    |> pool_section(tables.constants)
    |> structs(program)
    |> pool_section(json.types)
    |> Wire.add(Wire.u32(json.decodable_count))
    |> Wire.add_all(json.decodable)
    |> enums(program)
    |> pool_section(tables.updates)
    |> Wire.add(Wire.u32(program.globals))
    |> pool_section(tables.builtins)
    |> Wire.add(Wire.u32(program.functions.size))
    |> Wire.add_all(functions)
    |> Wire.add(Wire.u32(program.entry))
    |> decodable_enums(json, found.count > 0)
    |> Wire.add_all(found.chunks)
  )

  joined = Wire.join(out)
  return error(Failure.internal(program, joined.message)) if !joined.ok?

  ok(Built(bytes: joined.unwrap!, tables: tables))
end

# The decodable enums, after the entry: a count and the records, then the struct instances the same way. Each is
# written only when there is one to decode or a later section follows, so a program without one has the bytes it
# always had; a section is empty (a count of 0) only before the next one.
def decodable_enums(out: Wire.Chunks, json: JsonTypes.Section, more: Bool) -> Wire.Chunks
  return out if json.enums_count == 0 and json.instances_count == 0 and !more

  enums = Wire.add_all(Wire.add(out, Wire.u32(json.enums_count)), json.enums)
  return enums if json.instances_count == 0 and !more

  Wire.add_all(Wire.add(enums, Wire.u32(json.instances_count)), json.instances)
end

# The Field defaults section, last in the file: a count, then for each field with a default, in struct and field
# order, the struct, the field, a kind (1 constant, 2 empty List, 3 empty Map, 4 variant) and its number (the constant
# or the variant; 0 otherwise). The constants join the table.
def field_defaults(program: Ir.Program, constants: Pool.Pool) -> Defaults
  entries = Wire.start()
  count = 0
  pool = constants
  index = 0
  for entry in program.structs
    field = 0
    for default in entry.defaults
      kind = 0
      number = 0
      case default
        Ir.FieldDefault.Required -> kind = 0
        Ir.FieldDefault.Value(imm) ->
          interned = Function.intern_constant(pool, imm)
          pool = interned.pool
          kind = 1
          number = interned.id
        Ir.FieldDefault.EmptyList -> kind = 2
        Ir.FieldDefault.EmptyMap -> kind = 3
        Ir.FieldDefault.Variant(id) ->
          kind = 4
          number = id
      end

      if kind > 0
        record = Wire.u32(index).concat(Wire.u32(field)).concat(Wire.u32(kind)).concat(Wire.u32(number))
        entries = Wire.add(entries, record)
        count += 1
      end

      field += 1
    end

    index += 1
  end

  chunks = Wire.start()
  if count > 0
    chunks = Wire.add_all(Wire.add(chunks, Wire.u32(count)), entries)
  end

  Defaults(chunks: chunks, count: count, constants: pool)
end

# The first limits of the format, in this order. The limits of the types, the registers and the updates are met
# while those are written.
def check_limits(program: Ir.Program) -> Result[Void]
  span = program.span
  return error(Failure.limit(program, 0, "structs", span)) if program.structs.size > MAX_U16

  variants = 0
  for entry in program.enums
    variants += entry.variants.size
  end

  return error(Failure.limit(program, 0, "enum variants", span)) if variants > MAX_U16

  for entry in program.structs
    return error(Failure.limit(program, 0, "fields in one struct", span)) if entry.fields.size > MAX_U16
  end

  for entry in program.enums
    for variant in entry.variants
      return error(Failure.limit(program, 0, "payload items in one variant", span)) if variant.size > MAX_U16
    end
  end

  return error(Failure.limit(program, 0, "module constants", span)) if program.globals > MAX_U16

  ok()
end

# The magic, the format version and the Agentica version.
def header(version: String) -> Wire.Chunks
  out = Wire.add(Wire.start(), [65, 71, 67, 66])
  out = Wire.add(out, Wire.u32(FORMAT_VERSION))
  Wire.add_text(out, version)
end

# The count of a table of entries, then its entries.
def pool_section(out: Wire.Chunks, pool: Pool.Pool) -> Wire.Chunks
  Wire.add_all(Wire.add(out, Wire.u32(pool.count)), pool.chunks)
end

# The sources: the stored name of each file and its text.
def sources(out: Wire.Chunks, program: Ir.Program) -> Wire.Chunks
  chunks = Wire.add(out, Wire.u32(program.sources.size))
  for source in program.sources
    chunks = Wire.add_text(chunks, source.name)
    chunks = Wire.add_text(chunks, source.text)
  end

  chunks
end

# The name of a struct or an enum as the program writes it: display_name, with the import alias of its std/ module.
def written_name(program: Ir.Program, name: String) -> String
  bare = Types.display_name(name)
  alias = program.written.get(name.slice(0, name.length - bare.length), "")
  return bare if alias == ""

  "#{alias}.#{bare}"
end

# The structs: the name as the user wrote it, and the fields.
def structs(out: Wire.Chunks, program: Ir.Program) -> Wire.Chunks
  chunks = Wire.add(out, Wire.u32(program.structs.size))
  for entry in program.structs
    chunks = Wire.add_text(chunks, written_name(program, entry.name))
    chunks = Wire.add(chunks, Wire.u32(entry.fields.size))
    for field in entry.fields
      chunks = Wire.add_text(chunks, field)
    end
  end

  chunks
end

# The enums: the name as the user wrote it, and the variants with their payload sizes.
def enums(out: Wire.Chunks, program: Ir.Program) -> Wire.Chunks
  chunks = Wire.add(out, Wire.u32(program.enums.size))
  for entry in program.enums
    chunks = Wire.add_text(chunks, written_name(program, entry.name))
    chunks = Wire.add(chunks, Wire.u32(entry.variants.size))
    for variant in entry.variants
      chunks = Wire.add_text(chunks, variant.name)
      chunks = Wire.add(chunks, Wire.u32(variant.size))
    end
  end

  chunks
end
