# Zlib one-shot bytes: sizes and round trips of deflate/inflate (the zlib
# wrapper) and gzip/gunzip; tests/test_vm_zlib.py checks the bytes against
# Python's stdlib zlib and gzip.
def main() -> Void
  data = "hello".bytes
  none = "".bytes
  packed = Zlib.deflate(data).unwrap!
  puts("deflate #{packed.size} round #{Test.eq(Zlib.inflate(packed).unwrap!, data)}")
  empty_packed = Zlib.deflate(none, 6, 1048576).unwrap!
  puts("empty deflate #{empty_packed.size} round #{Test.eq(Zlib.inflate(empty_packed, 1048576).unwrap!, none)}")
  gz = Zlib.gzip(data, 9).unwrap!
  puts("gzip #{gz.size} round #{Test.eq(Zlib.gunzip(gz).unwrap!, data)}")
  empty_gz = Zlib.gzip(none, 6, 1048576).unwrap!
  puts("empty gzip #{empty_gz.size} round #{Test.eq(Zlib.gunzip(empty_gz, 1048576).unwrap!, none)}")
  puts("inflating nothing -> #{Zlib.inflate(none, 1048576)}")
  puts("gunzipping nothing -> #{Zlib.gunzip(none, 1048576)}")
  puts("zero max -> #{Zlib.deflate(data, 6, 0)}")
  puts("bad level -> #{Zlib.deflate(data, 10)}")
  puts("small max -> #{Zlib.inflate(packed, 4)}")
end
