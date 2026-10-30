import Wire from "../../../../compiler/bytecode/bytecode_bytes"

# Drives the chunks of the bytecode writer (compiler/bytecode/bytecode_bytes.agc) the way the writer does and prints one
# line for each scenario: its name, then `ok` and the bytes joined (comma separated, `-` for none) or `error` when join
# refuses. tests/test_frontend_wire.py holds the lines it expects.

def main() -> Void
  report("bad-open", Wire.join(Wire.add(Wire.start(), [1, 256])))
  report("bad-open-negative", Wire.join(Wire.add(Wire.start(), [-1])))
  report("bad-long", Wire.join(Wire.add(Wire.start(), List.concat(List.repeat(7, 40), [300]))))
  report("bad-merge-open", Wire.join(Wire.add_all(Wire.start(), Wire.add(Wire.start(), [300]))))
  report("bad-merge-first", Wire.join(Wire.add_all(Wire.add(Wire.start(), [300]), Wire.start())))
  report("bad-merge-done", Wire.join(Wire.add_all(Wire.start(), Wire.add(Wire.add(Wire.start(), List.repeat(1, 40)), [300]))))
  report("bad-after-ok", Wire.join(Wire.add(Wire.add(Wire.start(), [1, 2]), [3, 999])))
  report("empty", Wire.join(Wire.start()))
  report("small-pieces", Wire.join(Wire.add(Wire.add(Wire.start(), [1, 2]), [3])))
  report("order", Wire.join(ordered()))
  limit(4096)
  limit(4097)
  report("text-short", Wire.join(Wire.add_text(Wire.start(), "hi")))
  report("text-long", Wire.join(Wire.add_text(Wire.add(Wire.start(), [9]), List.repeat("a", 40).join(""))))
  report("text-multibyte", Wire.join(Wire.add_text(Wire.start(), List.repeat("é", 20).join(""))))
end

# [1] and [2] small, then a long piece, then [9]: add_all keeps the order of the sealed chunks and the open lists.
def ordered() -> Wire.Chunks
  first = Wire.add(Wire.add(Wire.start(), [1]), [2])
  more = Wire.add(Wire.add(Wire.add(Wire.start(), [3]), List.repeat(7, 40)), [9])
  return Wire.add_all(first, more)
end

# Adds n pieces of one byte: the open list is sealed by the add that makes it longer than 4096.
def limit(n: Int) -> Void
  chunks = Wire.start()
  for i in 0...n
    chunks = Wire.add(chunks, [i % 256])
  end

  puts("limit-#{n} sealed=#{chunks.done.size} open=#{chunks.open.size}")
  report("limit-#{n}-bytes", Wire.join(chunks))
end

def report(name: String, joined: Result[Bytes]) -> Void
  if !joined.ok?
    puts("#{name} error")
    return
  end

  data = joined.unwrap!
  if data.size == 0
    puts("#{name} ok -")
    return
  end

  puts("#{name} ok #{data.to_a.map do |b| b.to_s end.join(",")}")
end
