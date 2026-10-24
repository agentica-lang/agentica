# Zlib streaming: a deflate/inflate round trip through 1-byte outputs, the
# finish drain, and the close taxonomy; tests/test_vm_zlib.py checks the
# progress flags against Python's stdlib zlib.
def drain(enc: ZlibEncoder) -> List[Int]
  out: List[Int] = []
  again = true
  while again
    step = Zlib.deflate_next(enc, [], 1).unwrap!
    out = List.concat(out, step.output)
    again = not step.needs_input
  end
  return out
end

def main() -> Void
  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!
  head = Zlib.deflate_next(enc, [104, 101], 1).unwrap!
  puts("head #{head.output.size} consumed #{head.consumed} needs #{head.needs_input}")
  rest = drain(enc)
  tail = Zlib.deflate_finish(enc, 1)
  puts("tail #{tail} rest #{rest.size}")
  puts("close #{Zlib.encoder_close(enc).ok?} again #{Zlib.encoder_close(enc).ok?}")
  puts("feed after close -> #{Zlib.deflate_next(enc, [1], 1)}")
  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!
  puts("bad window -> #{Zlib.inflate_init(8, 1073741824, 1073741824).ok?}")
  puts("bad total -> #{Zlib.inflate_init(15, 0, 1073741824).ok?}")
  puts("close #{Zlib.decoder_close(dec).ok?}")
end
