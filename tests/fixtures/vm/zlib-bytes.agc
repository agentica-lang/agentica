# Zlib one-shot bytes: sizes and round trips of deflate/inflate (the zlib
# wrapper) and gzip/gunzip; tests/test_vm_zlib.py checks the bytes against
# Python's stdlib zlib and gzip.
def main() -> Void
  data: List[Int] = [104, 101, 108, 108, 111]
  packed = Zlib.deflate(data, 6, 1048576).unwrap!
  puts("deflate #{packed.size} round #{Test.eq(Zlib.inflate(packed, 1048576).unwrap!, data)}")
  empty_packed = Zlib.deflate([], 6, 1048576).unwrap!
  puts("empty deflate #{empty_packed.size} round #{Test.eq(Zlib.inflate(empty_packed, 1048576).unwrap!, [])}")
  gz = Zlib.gzip(data, 6, 1048576).unwrap!
  puts("gzip #{gz.size} round #{Test.eq(Zlib.gunzip(gz, 1048576).unwrap!, data)}")
  empty_gz = Zlib.gzip([], 6, 1048576).unwrap!
  puts("empty gzip #{empty_gz.size} round #{Test.eq(Zlib.gunzip(empty_gz, 1048576).unwrap!, [])}")
  puts("inflating nothing -> #{Zlib.inflate([], 1048576)}")
  puts("gunzipping nothing -> #{Zlib.gunzip([], 1048576)}")
  puts("zero max -> #{Zlib.deflate(data, 6, 0)}")
  puts("bad level -> #{Zlib.deflate(data, 10, 1048576)}")
end
