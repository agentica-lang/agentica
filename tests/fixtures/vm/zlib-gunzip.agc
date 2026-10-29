# File.chunks and Lazy.write_bytes around gunzip and gzip: small hardcoded
# members, the byte counts and the error taxonomy; tests/test_vm_zlib.py checks
# long inputs against Python's stdlib gzip.
def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def b(items: List[Int]) -> Bytes
  return Bytes.from_list(items).unwrap!
end

def abc_gz() -> List[Bytes]
  return [b([31, 139, 8, 0, 0, 0, 0, 0, 2, 255]), b([75, 76, 74, 6, 0]), b([194, 65, 36, 53, 3, 0, 0, 0])]
end

# The chunks of a Lazy as lists, to print them.
def lists(lazy: Lazy[Bytes]) -> Result[List[List[Int]]]
  return lazy.map do |chunk| chunk.to_a end.to_a
end

def main() -> Void
  dir: String = System.args()[0]
  abc = at(dir, "abc.gz")
  puts("write #{abc_gz().lazy.write_bytes(abc)}")
  puts("chunks #{lists(File.chunks(abc, 10))}")
  puts("gunzip #{File.chunks(abc).gunzip.write_bytes(at(dir, "abc.out"))}")
  puts("read #{lists(File.chunks(at(dir, "abc.out")))}")
  puts("gzip #{lists(File.chunks(at(dir, "abc.out"), 1).gzip.gunzip)}")
  puts("exact #{lists(File.chunks(abc, 1).gunzip(3))}")
  puts("over #{lists(File.chunks(abc, 1).gunzip(2))}")
  puts("missing -> #{File.chunks(at(dir, "missing.gz")).gunzip.to_a}")
  puts("directory -> #{File.chunks(dir).to_a}")
  puts("into a directory -> #{File.chunks(abc).gunzip.write_bytes(dir).ok?}")
  puts("zero timeout -> #{File.chunks(abc, 10, 0).to_a}")
end
