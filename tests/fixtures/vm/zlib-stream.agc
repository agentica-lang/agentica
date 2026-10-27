# Zlib through the Lazy steps: round trips of each wrapper over chunks of any
# size (empty ones too), the raw form, the caps and the strict decoders;
# tests/test_vm_zlib.py checks the bytes against Python's stdlib zlib.
def joined(chunks: List[List[Int]]) -> List[Int]
  return chunks.flat_map do |c| c end
end

def main() -> Void
  none: List[Int] = []
  items: List[List[Int]] = [[104, 101], none, [108], [108, 111], none]
  packed = items.lazy.deflate.to_a.unwrap!
  puts("deflate #{joined(packed).size} round #{packed.lazy.inflate.to_a}")
  raw = items.lazy.deflate(9, true).to_a.unwrap!
  puts("raw #{joined(raw).size} round #{raw.lazy.inflate(true).to_a}")
  puts("raw as zlib -> #{raw.lazy.inflate.to_a}")
  gz = items.lazy.gzip(1).to_a.unwrap!
  bytes = joined(gz)
  puts("gzip #{bytes.size} one byte at a time #{bytes.map do |b| [b] end.lazy.gunzip.to_a}")
  puts("one-shot agrees #{Test.eq(Zlib.gunzip(bytes).unwrap!, joined(items))}")
  puts("small cap -> #{gz.lazy.gunzip(4).to_a}")
  puts("exact cap -> #{gz.lazy.gunzip(5).to_a}")
  puts("trailing -> #{[bytes, [0]].lazy.gunzip.to_a}")
  puts("truncated -> #{[bytes.take(10)].lazy.gunzip.to_a}")
  puts("nothing -> #{[none].lazy.inflate.to_a}")
  puts("empty deflate #{joined([none].lazy.deflate.to_a.unwrap!)}")
  puts("bad level -> #{items.lazy.gzip(10).to_a}")
  puts("bad cap -> #{items.lazy.inflate(false, 0).to_a}")
  puts("first #{gz.lazy.gunzip.first(1)}")
end
