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
  empty = Wire.no_prefix()
  Function.Tables(
    constants: Pool.empty(),
    updates: Pool.empty(),
    builtins: Pool.empty(),
    spans: Pool.empty(),
    types: Pool.empty(),
    written: Function.Written(
      functions: empty,
      structs: empty,
      enums: empty,
      decodable: empty,
      decodable_enums: empty,
      instances: empty,
      defaults: empty,
      struct_index: {},
      enum_index: {},
      texts: [],
    ),
  )
end

## Writes the program over `seed`, the tables of an earlier program whose functions and types this one starts with:
## each entry of those tables keeps its number, as the session of `agentica repl` needs (compiler/repl/). The file
## has only the entries after the seed's, and of each source of the seed only the text it gained since, which the
## session's child loads over that program (vm/loader.c, a session load). Over no tables, it is the whole file.
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

# The functions of a program after the first `from`, with their Type constants as the Ints of their entries in the
# type table, and that table.
struct Typed
  functions: List[Ir.Function]
  types: Pool.Pool
end

# The records of the Field defaults section and the constant table with their constants.
struct Defaults
  records: Wire.Prefix
  constants: Pool.Pool
end

# A struct or an enum of a field type is found by its name, or by `#N` for the entry at N, which a session of
# `agentica repl` writes where a name may stand for several entries (compiler/repl/repl_image.agc).
# Each Type constant (Ir.Imm.Type) as the Int of the entry of its type in the type table, in the functions after the
# first `from`.
def typed_constants(
  program: Ir.Program,
  struct_index: Map[String, Int],
  enum_index: Map[String, Int],
  types: Pool.Pool,
  from: Int,
) -> Result[Typed]
  fresh = program.functions.drop(from)
  return ok(Typed(functions: fresh, types: types)) if !fresh.any?(&typed?)

  pool = types
  functions: List[Ir.Function] = []
  for function in fresh
    body: List[Ir.Instr] = []
    for instr in function.body
      out = instr
      case instr.imm
        Ir.Imm.Type(type) ->
          found = try JsonTypes.target(program, struct_index, enum_index, pool, type)
          pool = found.pool
          out = instr.with(imm: Ir.Imm.Int(found.id))
        _ -> out = instr
      end

      body = body.push(out)
    end

    functions = functions.push(function.with(body: body))
  end

  return error(Failure.limit(program, 0, "JSON field types", program.span)) if pool.count > MAX_U16

  ok(Typed(functions: functions, types: pool))
end

def typed?(function: Ir.Function) -> Bool
  function.body.any? do |instr: Ir.Instr|
    case instr.imm
      Ir.Imm.Type(_) -> true
      _ -> false
    end
  end
end

def build(program: Ir.Program, version: String, seed: Function.Tables) -> Result[Built]
  held = seed.written
  start = unwritten(seed)
  try check_limits(program, held.structs.count)
  struct_index = held.struct_index
  at = held.structs.count
  for entry in program.structs.drop(at)
    struct_index = struct_index.put(entry.name, at).put("##{at}", at)
    at += 1
  end

  enum_index = held.enum_index
  at = held.enums.count
  for entry in program.enums.drop(at)
    enum_index = enum_index.put(entry.name, at).put("##{at}", at)
    at += 1
  end

  sections = JsonTypes.Section(
    types: start.types,
    decodable: start.written.decodable,
    enums: start.written.decodable_enums,
    instances: start.written.instances,
  )

  built = try JsonTypes.build(program, struct_index, enum_index, start.types, sections)
  typed = try typed_constants(program, struct_index, enum_index, built.types, held.functions.count)
  json = built.with(types: typed.types)
  # The span of the program is the first run of the span table.
  tables = start.with(spans: Spans.intern_one(start.spans, 0, program.span).pool, types: json.types)
  functions = Wire.start()
  for function in typed.functions
    encoded = try Function.encode(program, tables, function)
    tables = encoded.tables
    functions = Wire.add_all(functions, encoded.parts)
  end

  found = field_defaults(program, tables.constants, start.written.defaults)
  written = Function.Written(
    functions: Wire.Prefix(count: program.functions.size, records: program.functions.size, chunks: functions),
    structs: struct_records(program, start.written.structs),
    enums: enum_records(program, start.written.enums),
    decodable: json.decodable,
    decodable_enums: json.enums,
    instances: json.instances,
    defaults: found.records,
    struct_index: struct_index,
    enum_index: enum_index,
    texts: program.sources.map { |source: Ir.SourceFile| source.text },
  )

  tables = tables.with(constants: found.constants, written: written)
  head = try sources(header(version), program, held.texts)
  out = (
    head
    |> pool_section(tables.spans, seed.spans)
    |> pool_section(tables.constants, seed.constants)
    |> records(written.structs, held.structs)
    |> pool_section(json.types, seed.types)
    |> records(json.decodable, held.decodable)
    |> records(written.enums, held.enums)
    |> pool_section(tables.updates, seed.updates)
    |> Wire.add(Wire.u32(program.globals))
    |> pool_section(tables.builtins, seed.builtins)
    |> records(written.functions, held.functions)
    |> Wire.add(Wire.u32(program.entry))
    |> decodable_enums(json, held, found.records.records > held.defaults.records)
    |> field_default_section(found.records, held.defaults)
  )

  joined = Wire.join(out)
  return error(Failure.internal(program, joined.message)) if !joined.ok?

  ok(Built(bytes: joined.unwrap!, tables: tables))
end

# The seed with no bytes in its tables, which then hold only what is written after it.
def unwritten(seed: Function.Tables) -> Function.Tables
  held = seed.written
  seed.with(
    constants: blank(seed.constants),
    updates: blank(seed.updates),
    builtins: blank(seed.builtins),
    spans: blank(seed.spans),
    types: blank(seed.types),
    written: held.with(
      functions: blank_records(held.functions),
      structs: blank_records(held.structs),
      enums: blank_records(held.enums),
      decodable: blank_records(held.decodable),
      decodable_enums: blank_records(held.decodable_enums),
      instances: blank_records(held.instances),
      defaults: blank_records(held.defaults),
    ),
  )
end

def blank(pool: Pool.Pool) -> Pool.Pool = pool.with(chunks: Wire.start())

def blank_records(prefix: Wire.Prefix) -> Wire.Prefix = prefix.with(chunks: Wire.start())

# The decodable enums, after the entry: a count and the records, then the struct instances the same way. Each is
# written only when there is a new one or a later section follows, so a program without one has the bytes it always
# had; a section is empty (a count of 0) only before the next one.
def decodable_enums(out: Wire.Chunks, json: JsonTypes.Section, held: Function.Written, more: Bool) -> Wire.Chunks
  instances = json.instances.records > held.instances.records or more
  return out if json.enums.records == held.decodable_enums.records and !instances

  enums = records(out, json.enums, held.decodable_enums)
  return enums if !instances

  records(enums, json.instances, held.instances)
end

# A section of records: the number of those after `held`, then their bytes.
def records(out: Wire.Chunks, prefix: Wire.Prefix, held: Wire.Prefix) -> Wire.Chunks
  Wire.add_all(Wire.add(out, Wire.u32(prefix.records - held.records)), prefix.chunks)
end

# The Field defaults section, written only when it has a new record.
def field_default_section(out: Wire.Chunks, prefix: Wire.Prefix, held: Wire.Prefix) -> Wire.Chunks
  return out if prefix.records == held.records

  records(out, prefix, held)
end

# The Field defaults section, last in the file: a count, then for each field with a default, in struct and field
# order, the struct, the field, a kind (1 constant, 2 empty List, 3 empty Map, 4 variant) and its number (the constant
# or the variant; 0 otherwise). The constants join the table.
def field_defaults(program: Ir.Program, constants: Pool.Pool, held: Wire.Prefix) -> Defaults
  entries = held.chunks
  count = held.records
  pool = constants
  index = held.count
  for entry in program.structs.drop(held.count)
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

  Defaults(records: Wire.Prefix(count: program.structs.size, records: count, chunks: entries), constants: pool)
end

# The first limits of the format, in this order. The limits of the types, the registers and the updates are met
# while those are written. The first `held` structs were checked when they were written.
def check_limits(program: Ir.Program, held: Int) -> Result[Void]
  span = program.span
  return error(Failure.limit(program, 0, "structs", span)) if program.structs.size > MAX_U16

  variants = 0
  for entry in program.enums
    variants += entry.variants.size
  end

  return error(Failure.limit(program, 0, "enum variants", span)) if variants > MAX_U16

  for entry in program.structs.drop(held)
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

# A table of entries: the number of those after the seed's, then their bytes.
def pool_section(out: Wire.Chunks, pool: Pool.Pool, seed: Pool.Pool) -> Wire.Chunks
  Wire.add_all(Wire.add(out, Wire.u32(pool.count - seed.count)), pool.chunks)
end

# The sources: the stored name of each file and its text. A source of the seed, whose text as written then is in
# `held`, has only the text it gained since: a session's text only grows.
def sources(out: Wire.Chunks, program: Ir.Program, held: List[String]) -> Result[Wire.Chunks]
  chunks = Wire.add(out, Wire.u32(program.sources.size))
  at = 0
  for source in program.sources
    text = source.text
    if at < held.size
      before = held[at]
      if !text.start_with?(before)
        return error(Failure.internal(program, "the text of a source of the session changed"))
      end

      text = text.slice(before.length, text.length - before.length)
    end

    chunks = Wire.add_text(Wire.add_text(chunks, source.name), text)
    at += 1
  end

  ok(chunks)
end

# The name of a struct or an enum as the program writes it: display_name, with the import alias of its std/ module.
def written_name(program: Ir.Program, name: String) -> String
  bare = Types.display_name(name)
  alias = program.written.get(name.slice(0, name.length - bare.length), "")
  return bare if alias == ""

  "#{alias}.#{bare}"
end

# The records of the structs, after those of `held`: the name as the user wrote it, and the fields.
def struct_records(program: Ir.Program, held: Wire.Prefix) -> Wire.Prefix
  chunks = held.chunks
  for entry in program.structs.drop(held.count)
    chunks = Wire.add_text(chunks, written_name(program, entry.name))
    chunks = Wire.add(chunks, Wire.u32(entry.fields.size))
    for field in entry.fields
      chunks = Wire.add_text(chunks, field)
    end
  end

  Wire.Prefix(count: program.structs.size, records: program.structs.size, chunks: chunks)
end

# The records of the enums, after those of `held`: the name as the user wrote it, and the variants with their payload
# sizes.
def enum_records(program: Ir.Program, held: Wire.Prefix) -> Wire.Prefix
  chunks = held.chunks
  for entry in program.enums.drop(held.count)
    chunks = Wire.add_text(chunks, written_name(program, entry.name))
    chunks = Wire.add(chunks, Wire.u32(entry.variants.size))
    for variant in entry.variants
      chunks = Wire.add_text(chunks, variant.name)
      chunks = Wire.add(chunks, Wire.u32(variant.size))
    end
  end

  Wire.Prefix(count: program.enums.size, records: program.enums.size, chunks: chunks)
end
