## The span table of the .agcb: runs of spans, one run for the spans of each instruction and each function. Two runs
## with the same spans are one entry, so an instruction names its run by the number of the first span, and a run may be
## empty. A span is written as the index of its source and the line and column of its start and end.

import Ir from "../lower/ir"
import Source from "../syntax/source"
import Pool from "bytecode_pool"

## The run of the spans of the written instruction that starts at body[at] and stands for `count` instructions (more
## than one for a run of `step`): the pool with it added when it is new, and its number. Nearly every instruction has
## one span, which skips the lists the general case builds.
export def intern_run(pool: Pool.Pool, body: List[Ir.Instr], at: Int, count: Int) -> Pool.Interned
  # With one instruction and one span the general path below has keys = [span_key(file, span)], so its key is that one
  # key (join of one item) and run_bytes is span_bytes(file, span): intern_one builds exactly the same key and bytes.
  first = body[at]
  if count == 1 and first.spans.size == 1
    return intern_one(pool, first.file, first.spans[0])
  end

  keys: List[String] = []
  for offset in 0...count
    instr = body[at + offset]
    for span in instr.spans
      keys = keys.push(span_key(instr.file, span))
    end
  end

  key = keys.join(";")
  found = Pool.find(pool, key)
  if found.some?
    return Pool.Interned(pool: pool, id: found.unwrap!)
  end

  return Pool.Interned(pool: Pool.add(pool, key, run_bytes(body, at, count), keys.size), id: pool.count)
end

## The run of one span in the source at index file.
export def intern_one(pool: Pool.Pool, file: Int, span: Source.Span) -> Pool.Interned
  key = span_key(file, span)
  found = Pool.find(pool, key)
  if found.some?
    return Pool.Interned(pool: pool, id: found.unwrap!)
  end

  return Pool.Interned(pool: Pool.add(pool, key, span_bytes(file, span), 1), id: pool.count)
end

# The key of a run is the keys of its spans joined with ";", so a run of one span has this key.
def span_key(file: Int, span: Source.Span) -> String
  start = span.start
  stop = span.stop
  return "#{file},#{start.line},#{start.column},#{stop.line},#{stop.column}"
end

# The bytes of a run. Joining u32 lists is cheaper here than pushing each byte, which was measured slower.
def run_bytes(body: List[Ir.Instr], at: Int, count: Int) -> List[Int]
  entry: List[Int] = []
  for offset in 0...count
    instr = body[at + offset]
    for span in instr.spans
      entry = entry.concat(span_bytes(instr.file, span))
    end
  end

  return entry
end

# The five numbers of a span as u32, written out in one list: that costs about half of five calls of Wire.u32. Nearly
# every number is below 65536 and has two zero high bytes, which the first list leaves out of the arithmetic. Both
# lists are Wire.u32 of file, line, column, line, column joined: for a number below 65536 u32 gives [n % 256, n / 256,
# 0, 0], and the second list is its general formula. The numbers are never negative (see Wire.u32).
def span_bytes(file: Int, span: Source.Span) -> List[Int]
  start = span.start
  stop = span.stop
  first = start.line
  second = start.column
  third = stop.line
  fourth = stop.column
  if file < 65_536 and first < 65_536 and second < 65_536 and third < 65_536 and fourth < 65_536
    return [
      file % 256,
      file / 256,
      0,
      0,
      first % 256,
      first / 256,
      0,
      0,
      second % 256,
      second / 256,
      0,
      0,
      third % 256,
      third / 256,
      0,
      0,
      fourth % 256,
      fourth / 256,
      0,
      0,
    ]
  end

  return [
    file % 256,
    (file / 256) % 256,
    (file / 65_536) % 256,
    file / 16_777_216,
    first % 256,
    (first / 256) % 256,
    (first / 65_536) % 256,
    first / 16_777_216,
    second % 256,
    (second / 256) % 256,
    (second / 65_536) % 256,
    second / 16_777_216,
    third % 256,
    (third / 256) % 256,
    (third / 65_536) % 256,
    third / 16_777_216,
    fourth % 256,
    (fourth / 256) % 256,
    (fourth / 65_536) % 256,
    fourth / 16_777_216,
  ]
end
