## The span table of the .agcb: runs of spans, one run for the spans of each instruction and each function. Two runs
## with the same spans are one entry, so an instruction names its run by the number of the first span, and a run may be
## empty. A span is written as the index of its source and the line and column of its start and end.

import Bytes from "bytecode_bytes"
import Pool from "bytecode_pool"
import Ir from "ir"
import Source from "source"

## A span with the index of the source it is in.
export struct Placed
  file: Int
  span: Source.Span
end

## The run of the spans of the instructions, in order: the pool with it added when it is new, and its number.
export def intern_instrs(pool: Pool.Pool, instrs: List[Ir.Instr]) -> Pool.Interned
  spans: List[Placed] = []
  for instr in instrs
    for span in instr.spans
      spans = spans.push(Placed(file: instr.file, span: span))
    end
  end
  return intern(pool, spans)
end

## The run of one span in the source at index file.
export def intern_one(pool: Pool.Pool, file: Int, span: Source.Span) -> Pool.Interned
  return intern(pool, [Placed(file: file, span: span)])
end

## The run of the spans, in order: the pool with it added when it is new, and its number.
export def intern(pool: Pool.Pool, spans: List[Placed]) -> Pool.Interned
  keys = spans.map do |placed: Placed| span_key(placed) end
  key = keys.join(";")
  found = Pool.find(pool, key)
  if found.ok?
    return Pool.Interned(pool: pool, id: found.unwrap!)
  end
  return Pool.Interned(pool: Pool.add(pool, key, run_bytes(spans), keys.size), id: pool.count)
end

def span_key(placed: Placed) -> String
  span = placed.span
  return "#{placed.file},#{span.start.line},#{span.start.column},#{span.stop.line},#{span.stop.column}"
end

# The bytes of a run. Joining u32 lists is cheaper here than pushing each byte, which was measured slower.
def run_bytes(spans: List[Placed]) -> List[Int]
  entry: List[Int] = []
  for placed in spans
    span = placed.span
    entry = entry.concat(Bytes.u32(placed.file)).concat(Bytes.u32(span.start.line))
    entry = entry.concat(Bytes.u32(span.start.column)).concat(Bytes.u32(span.stop.line))
    entry = entry.concat(Bytes.u32(span.stop.column))
  end
  return entry
end
