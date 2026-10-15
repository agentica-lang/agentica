## The bytecode writer (src/bytecode.rkt, `ir->bytecode` and `write-bytecode`): the .agcb bytes of a lowered program.
## The file is, in this order, the header, the sources, the spans, the constants, the structs, the JSON field types,
## the Decodable structs, the enums, the struct updates, the Globals count, the builtins, the functions and the entry
## (docs/vm/03-ir-and-bytecode.md 4.6). The bytes are the same as the Racket writer's, which a test compares.
##
## The functions are walked first, because they decide the entries of the constant, update, builtin and span tables,
## which come before them in the file. The output is a list of chunks that is joined once at the end.
##
## Recursion: only the JSON field types recurse (bytecode_types.agc, 1 VM frame for each level, at most 1,024 levels).

import Bytes from "bytecode_bytes"
import Failure from "bytecode_failure"
import Function from "bytecode_function"
import Pool from "bytecode_pool"
import Spans from "bytecode_spans"
import {FORMAT_VERSION, MAX_U16, VERSION} from "bytecode_tables"
import JsonTypes from "bytecode_types"
import Problems from "check_failure"
import Paths from "import_path"
import Ir from "ir"
import Types from "types"

## The result of writing: the bytes of the file, or the first problem (BYTECODE-LIMIT or BYTECODE-INTERNAL).
export enum Written
  Done(List[Int])
  Failed(Problems.Problem)
end

## Writes the program. root_dir is the folder of the root file, which the stored names of the sources are relative to.
export def write(root_dir: String, program: Ir.Program) -> Written
  result = build(root_dir, program)
  if result.ok?
    return Written.Done(result.unwrap!)
  end
  return Written.Failed(Problems.unpack(result.message))
end

def build(root_dir: String, program: Ir.Program) -> Result[List[Int]]
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
  functions = Bytes.start()
  for function in program.functions
    encoded = try Function.encode(program, tables, function)
    tables = encoded.tables
    functions = Bytes.add_all(functions, encoded.parts)
  end
  out = header()
  out = sources(out, root_dir, program)
  out = pool_section(out, tables.spans)
  out = pool_section(out, tables.constants)
  out = structs(out, program)
  out = pool_section(out, json.types)
  out = Bytes.add(out, Bytes.u32(json.decodable_count))
  out = Bytes.add_all(out, json.decodable)
  out = enums(out, program)
  out = pool_section(out, tables.updates)
  out = Bytes.add(out, Bytes.u32(program.globals))
  out = pool_section(out, tables.builtins)
  out = Bytes.add(out, Bytes.u32(program.functions.size))
  out = Bytes.add_all(out, functions)
  out = Bytes.add(out, Bytes.u32(program.entry))
  return ok(Bytes.join(out))
end

# The first limits of src/bytecode.rkt, in its order. The limits of the types, the registers and the updates are met
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
def header() -> List[List[Int]]
  out = Bytes.add(Bytes.start(), [65, 71, 67, 66])
  out = Bytes.add(out, Bytes.u32(FORMAT_VERSION))
  return Bytes.add(out, Bytes.string(VERSION))
end

# The count of a table of entries, then its entries.
def pool_section(out: List[List[Int]], pool: Pool.Pool) -> List[List[Int]]
  return Bytes.add_all(Bytes.add(out, Bytes.u32(pool.count)), pool.chunks)
end

# The sources: the stored name of each file and its text.
def sources(out: List[List[Int]], root_dir: String, program: Ir.Program) -> List[List[Int]]
  chunks = Bytes.add(out, Bytes.u32(program.sources.size))
  for source in program.sources
    chunks = Bytes.add(chunks, Bytes.string(Paths.stored_file(root_dir, source.file)))
    chunks = Bytes.add(chunks, Bytes.string(source.text))
  end
  return chunks
end

# The structs: the name as the user wrote it, and the fields.
def structs(out: List[List[Int]], program: Ir.Program) -> List[List[Int]]
  chunks = Bytes.add(out, Bytes.u32(program.structs.size))
  for entry in program.structs
    chunks = Bytes.add(chunks, Bytes.string(Types.display_name(entry.name)))
    chunks = Bytes.add(chunks, Bytes.u32(entry.fields.size))
    for field in entry.fields
      chunks = Bytes.add(chunks, Bytes.string(field))
    end
  end
  return chunks
end

# The enums: the name as the user wrote it, and the variants with their payload sizes.
def enums(out: List[List[Int]], program: Ir.Program) -> List[List[Int]]
  chunks = Bytes.add(out, Bytes.u32(program.enums.size))
  for entry in program.enums
    chunks = Bytes.add(chunks, Bytes.string(Types.display_name(entry.name)))
    chunks = Bytes.add(chunks, Bytes.u32(entry.variants.size))
    for variant in entry.variants
      chunks = Bytes.add(chunks, Bytes.string(variant.name))
      chunks = Bytes.add(chunks, Bytes.u32(variant.size))
    end
  end
  return chunks
end
