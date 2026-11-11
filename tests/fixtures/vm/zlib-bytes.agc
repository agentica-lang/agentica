# Zlib one-shot bytes: sizes and round trips of deflate/inflate (the zlib
# wrapper) and gzip/gunzip, and the decoder's limits: an exact-fit max, a cut
# stream, a trailing byte and a broken checksum. tests/test_vm_zlib.py checks
# the bytes against Python's stdlib zlib and gzip.
def main() -> Void
  data = "hello".bytes
  no_bytes = "".bytes
  packed = Zlib.deflate(data).unwrap!
  puts("deflate #{packed.size} round #{Test.eq(Zlib.inflate(packed).unwrap!, data)}")
  empty_packed = Zlib.deflate(no_bytes, 6, 1048576).unwrap!
  puts("empty deflate #{empty_packed.size} round #{Test.eq(Zlib.inflate(empty_packed, 1048576).unwrap!, no_bytes)}")
  gz = Zlib.gzip(data, 9).unwrap!
  puts("gzip #{gz.size} round #{Test.eq(Zlib.gunzip(gz).unwrap!, data)}")
  empty_gz = Zlib.gzip(no_bytes, 6, 1048576).unwrap!
  puts("empty gzip #{empty_gz.size} round #{Test.eq(Zlib.gunzip(empty_gz, 1048576).unwrap!, no_bytes)}")
  puts("inflating nothing -> #{Zlib.inflate(no_bytes, 1048576)}")
  puts("gunzipping nothing -> #{Zlib.gunzip(no_bytes, 1048576)}")
  puts("zero max -> #{Zlib.deflate(data, 6, 0)}")
  puts("bad level -> #{Zlib.deflate(data, 10)}")
  puts("small max -> #{Zlib.inflate(packed, 4)}")
  puts("exact max -> #{Zlib.inflate(packed, 5)}")
  puts("truncated -> #{Zlib.inflate(packed.take(packed.size - 1))}")
  puts("trailing byte -> #{Zlib.inflate(packed + "x".bytes)}")
  puts("bad adler -> #{Zlib.inflate(flip(packed, packed.size - 1))}")
  puts("bad crc -> #{Zlib.gunzip(flip(gz, gz.size - 8))}")
end

# DATA with the byte at INDEX changed, to break a checksum.
def flip(data: Bytes, index: Int) -> Bytes
  data.take(index) + Bytes.from_list([(data[index] + 1) % 256]).unwrap! + data.drop(index + 1)
end
