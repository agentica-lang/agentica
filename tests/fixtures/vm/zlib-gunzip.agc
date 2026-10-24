# Zlib.gunzip_file of small hardcoded members, its error taxonomy and its
# byte counts; tests/test_vm_zlib.py checks long inputs against Python's
# stdlib gzip.
def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def put_bytes(dir: String, name: String, bytes: List[Int]) -> String
  path = at(dir, name)
  out = Result.unwrap!(File.open(path, "write", 60000))
  Result.unwrap!(File.write_bytes(out, bytes, 60000))
  Result.unwrap!(File.close(out, 60000))
  return path
end

def empty_gz() -> List[Int]
  return [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]
end

def abc_gz() -> List[Int]
  return [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 76, 74, 6, 0, 194, 65, 36, 53, 3, 0, 0, 0]
end

def main() -> Void
  dir: String = System.args()[0]
  empty = put_bytes(dir, "empty.gz", empty_gz())
  abc = put_bytes(dir, "abc.gz", abc_gz())
  empty_out = at(dir, "empty.out")
  abc_out = at(dir, "abc.out")
  puts("empty #{Zlib.gunzip_file(empty, empty_out, 100, 60000)}")
  puts("abc #{Zlib.gunzip_file(abc, abc_out, 100, 60000)}")
  puts("exact #{Zlib.gunzip_file(abc, at(dir, "exact.out"), 3, 60000)}")
  puts("over #{Zlib.gunzip_file(abc, at(dir, "over.out"), 2, 60000)}")
  puts("missing -> #{Zlib.gunzip_file(at(dir, "missing.gz"), at(dir, "missing.out"), 100, 60000)}")
  puts("directory -> #{Zlib.gunzip_file(dir, at(dir, "dir.out"), 100, 60000)}")
  puts("exists -> #{Zlib.gunzip_file(abc, abc_out, 100, 60000)}")
  puts("empty path -> #{Zlib.gunzip_file("", abc_out, 100, 60000)}")
  puts("zero max -> #{Zlib.gunzip_file(abc, at(dir, "zero.out"), 0, 60000)}")
  puts("huge max -> #{Zlib.gunzip_file(abc, at(dir, "huge.out"), 1073741825, 60000)}")
  puts("zero timeout -> #{Zlib.gunzip_file(abc, at(dir, "slow.out"), 100, 0)}")
end
