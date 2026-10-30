# Zlib through the Lazy steps: round trips of each wrapper over chunks of any
# size (empty ones too), the raw form, the caps and the strict decoders;
# tests/test_vm_zlib.py checks the bytes against Python's stdlib zlib.
def b(items: List[Int]) -> Bytes
  return Bytes.from_list(items).unwrap!
end

# The chunks of a Lazy as lists, to print them.
def lists(lazy: Lazy[Bytes]) -> Result[List[List[Int]]]
  return lazy.map do |chunk| chunk.to_a end.to_a
end

def main() -> Void
  no_bytes = "".bytes
  items: List[Bytes] = [b([104, 101]), no_bytes, b([108]), b([108, 111]), no_bytes]
  packed = items.lazy.deflate.to_a.unwrap!
  puts("deflate #{Bytes.concat(packed).size} round #{lists(packed.lazy.inflate)}")
  raw = items.lazy.deflate(9, true).to_a.unwrap!
  puts("raw #{Bytes.concat(raw).size} round #{lists(raw.lazy.inflate(true))}")
  puts("raw as zlib -> #{raw.lazy.inflate.to_a}")
  gz = items.lazy.gzip(1).to_a.unwrap!
  bytes = Bytes.concat(gz)
  singles = bytes.to_a.map do |x| b([x]) end
  puts("gzip #{bytes.size} one byte at a time #{lists(singles.lazy.gunzip)}")
  puts("one-shot agrees #{Test.eq(Zlib.gunzip(bytes).unwrap!, Bytes.concat(items))}")
  puts("small cap -> #{gz.lazy.gunzip(4).to_a}")
  puts("exact cap -> #{lists(gz.lazy.gunzip(5))}")
  puts("trailing -> #{[bytes, b([0])].lazy.gunzip.to_a}")
  puts("truncated -> #{[bytes.take(10)].lazy.gunzip.to_a}")
  puts("nothing -> #{[no_bytes].lazy.inflate.to_a}")
  puts("empty deflate #{Bytes.concat([no_bytes].lazy.deflate.to_a.unwrap!).to_a}")
  puts("bad level -> #{items.lazy.gzip(10).to_a}")
  puts("bad cap -> #{items.lazy.inflate(false, 0).to_a}")
  puts("first #{lists(gz.lazy.gunzip.take(1))}")
end
