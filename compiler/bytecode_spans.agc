## The span table of the .agcb: runs of spans, one run for the spans of each instruction and each function. Two runs
## with the same spans are one entry, so an instruction names its run by the number of the first span, and a run may be
## empty. A span is written as the index of its source and the line and column of its start and end.

import Bytes from "bytecode_bytes"
import Pool from "bytecode_pool"
import Ir from "ir"
import Source from "source"

## The run of the spans of the instructions, in order: the pool with it added when it is new, and its number.
export def intern(pool: Pool.Pool, instrs: List[Ir.Instr]) -> Pool.Interned
  keys: List[String] = []
  for instr in instrs
    for span in instr.spans
      keys = keys.push(span_key(instr.file, span))
    end
  end
  key = keys.join(";")
  if pool.index.has_key?(key)
    return Pool.Interned(pool: pool, id: pool.index[key])
  end
  entry: List[Int] = []
  for instr in instrs
    for span in instr.spans
      entry = entry.concat(Bytes.u32(instr.file)).concat(Bytes.u32(span.start.line))
      entry = entry.concat(Bytes.u32(span.start.column)).concat(Bytes.u32(span.stop.line))
      entry = entry.concat(Bytes.u32(span.stop.column))
    end
  end
  return Pool.Interned(pool: Pool.add(pool, key, entry, keys.size), id: pool.count)
end

## The run of one span in the source at index file.
export def intern_one(pool: Pool.Pool, file: Int, span: Source.Span) -> Pool.Interned
  # An instruction is only the carrier of the file and the span.
  return intern(pool, [Ir.instr("span", [], file, [span])])
end

def span_key(file: Int, span: Source.Span) -> String
  return "#{file},#{span.start.line},#{span.start.column},#{span.stop.line},#{span.stop.column}"
end
