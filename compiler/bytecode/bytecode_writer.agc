## The bytecode writer: the .agcb bytes of a lowered program.
## The file is, in this order, the header, the sources, the spans, the constants, the structs, the JSON field types,
## the Decodable structs, the enums, the struct updates, the Globals count, the builtins, the functions and the entry
## (docs/vm/03-ir-and-bytecode.md 4.6). tests/test_frontend_bytecode.py compares them with frozen goldens.
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
export enum Written
  Done(Bytes)
  Failed(Problems.Problem)
end

## Writes the program. version is the Agentica version that the header names; the VM loads the file only when it is
## its own, so an empty one is BYTECODE-INTERNAL.
export def write(program: Ir.Program, version: String) -> Written
  if version == ""
    return Written.Failed(Problems.unpack(Failure.internal(program, "the Agentica version is empty")))
  end

  result = build(program, version)
  if result.ok?
    return Written.Done(result.unwrap!)
  end

  return Written.Failed(Problems.unpack(result.message))
end

def build(program: Ir.Program, version: String) -> Result[Bytes]
  try check_limits(program)
  struct_index: Map[String, Int] = {}
  at = 0
  for entry in program.structs
    struct_index = struct_index.put(entry.name, at)
    at += 1
  end

  json = try JsonTypes.build(program, struct_index)
  # The span of the program is the first run of the span table.
  spans = Spans.intern_one(Pool.empty(), 0, program.span).pool
  tables = Function.Tables(constants: Pool.empty(), updates: Pool.empty(), builtins: Pool.empty(), spans: spans)
  functions = Wire.start()
  for function in program.functions
    encoded = try Function.encode(program, tables, function)
    tables = encoded.tables
    functions = Wire.add_all(functions, encoded.parts)
  end

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
  )
  joined = Wire.join(out)
  if !joined.ok?
    return error(Failure.internal(program, joined.message))
  end

  return joined
end

# The first limits of the format, in this order. The limits of the types, the registers and the updates are met
# while those are written.
def check_limits(program: Ir.Program) -> Result[Void]
  span = program.span
  if program.structs.size > MAX_U16
    return error(Failure.limit(program, 0, "structs", span))
  end

  variants = 0
  for entry in program.enums
    variants += entry.variants.size
  end

  if variants > MAX_U16
    return error(Failure.limit(program, 0, "enum variants", span))
  end

  for entry in program.structs
    if entry.fields.size > MAX_U16
      return error(Failure.limit(program, 0, "fields in one struct", span))
    end
  end

  for entry in program.enums
    for variant in entry.variants
      if variant.size > MAX_U16
        return error(Failure.limit(program, 0, "payload items in one variant", span))
      end
    end
  end

  if program.globals > MAX_U16
    return error(Failure.limit(program, 0, "module constants", span))
  end

  return ok()
end

# The magic, the format version and the Agentica version.
def header(version: String) -> Wire.Chunks
  out = Wire.add(Wire.start(), [65, 71, 67, 66])
  out = Wire.add(out, Wire.u32(FORMAT_VERSION))
  return Wire.add_text(out, version)
end

# The count of a table of entries, then its entries.
def pool_section(out: Wire.Chunks, pool: Pool.Pool) -> Wire.Chunks
  return Wire.add_all(Wire.add(out, Wire.u32(pool.count)), pool.chunks)
end

# The sources: the stored name of each file and its text.
def sources(out: Wire.Chunks, program: Ir.Program) -> Wire.Chunks
  chunks = Wire.add(out, Wire.u32(program.sources.size))
  for source in program.sources
    chunks = Wire.add_text(chunks, source.name)
    chunks = Wire.add_text(chunks, source.text)
  end

  return chunks
end

# The structs: the name as the user wrote it, and the fields.
def structs(out: Wire.Chunks, program: Ir.Program) -> Wire.Chunks
  chunks = Wire.add(out, Wire.u32(program.structs.size))
  for entry in program.structs
    chunks = Wire.add_text(chunks, Types.display_name(entry.name))
    chunks = Wire.add(chunks, Wire.u32(entry.fields.size))
    for field in entry.fields
      chunks = Wire.add_text(chunks, field)
    end
  end

  return chunks
end

# The enums: the name as the user wrote it, and the variants with their payload sizes.
def enums(out: Wire.Chunks, program: Ir.Program) -> Wire.Chunks
  chunks = Wire.add(out, Wire.u32(program.enums.size))
  for entry in program.enums
    chunks = Wire.add_text(chunks, Types.display_name(entry.name))
    chunks = Wire.add(chunks, Wire.u32(entry.variants.size))
    for variant in entry.variants
      chunks = Wire.add_text(chunks, variant.name)
      chunks = Wire.add(chunks, Wire.u32(variant.size))
    end
  end

  return chunks
end
