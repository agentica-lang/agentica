# Zlib streaming: a deflate/inflate round trip through 1-byte outputs, the
# finish drain, and the close taxonomy; tests/test_vm_zlib.py checks the
# progress flags against Python's stdlib zlib.
def main() -> Void
  data: List[Int] = [104, 101]
  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!
  head = Zlib.deflate_next(enc, data, 1).unwrap!
  puts("head #{head.output.size} consumed #{head.consumed} needs #{head.needs_input}")
  out: List[Int] = head.output
  rest: List[Int] = List.drop(data, head.consumed)
  for i in 1..100
    if rest.size == 0
      break
    end
    step = Zlib.deflate_next(enc, List.take(rest, 7), 1).unwrap!
    out = List.concat(out, step.output)
    rest = List.drop(rest, step.consumed)
  end
  puts("fed rest #{rest.size} out #{out.size}")
  tail: List[Int] = []
  finished = false
  for i in 1..100
    fin = Zlib.deflate_finish(enc, 1).unwrap!
    tail = List.concat(tail, fin.output)
    finished = fin.finished
    if finished
      break
    end
  end
  puts("tail finished #{finished} tail #{tail.size}")
  packed = List.concat(out, tail)
  puts("round #{Test.eq(Zlib.inflate(packed, 1048576).unwrap!, data)}")
  puts("close #{Zlib.encoder_close(enc).ok?} again #{Zlib.encoder_close(enc).ok?}")
  puts("feed after close -> #{Zlib.deflate_next(enc, [1], 1)}")
  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!
  puts("bad window -> #{Zlib.inflate_init(8, 1073741824, 1073741824).ok?}")
  puts("bad total -> #{Zlib.inflate_init(15, 0, 1073741824).ok?}")
  puts("close #{Zlib.decoder_close(dec).ok?}")
end
