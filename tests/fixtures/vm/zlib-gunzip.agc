# File.chunks and Lazy.write_bytes around gunzip and gzip: small hardcoded
# members, the byte counts and the error taxonomy; tests/test_vm_zlib.py checks
# long inputs against Python's stdlib gzip.
def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def abc_gz() -> List[List[Int]]
  return [[31, 139, 8, 0, 0, 0, 0, 0, 2, 255], [75, 76, 74, 6, 0], [194, 65, 36, 53, 3, 0, 0, 0]]
end

def main() -> Void
  dir: String = System.args()[0]
  abc = at(dir, "abc.gz")
  puts("write #{abc_gz().lazy.write_bytes(abc)}")
  puts("chunks #{File.chunks(abc, 10).to_a}")
  puts("gunzip #{File.chunks(abc).gunzip.write_bytes(at(dir, "abc.out"))}")
  puts("read #{File.chunks(at(dir, "abc.out")).to_a}")
  puts("gzip #{File.chunks(at(dir, "abc.out"), 1).gzip.gunzip.to_a}")
  puts("exact #{File.chunks(abc, 1).gunzip(3).to_a}")
  puts("over #{File.chunks(abc, 1).gunzip(2).to_a}")
  puts("missing -> #{File.chunks(at(dir, "missing.gz")).gunzip.to_a}")
  puts("directory -> #{File.chunks(dir).to_a}")
  puts("into a directory -> #{File.chunks(abc).gunzip.write_bytes(dir).ok?}")
  puts("byte range -> #{[[1, 300]].lazy.write_bytes(at(dir, "bad.bin"))}")
  puts("zero timeout -> #{File.chunks(abc, 10, 0).to_a}")
end
