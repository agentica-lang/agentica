# File.sha256 of small known inputs, its error taxonomy and its agreement with Digest.sha256; tests/test_vm_file_sha256.py
# checks long inputs against hashlib.
def hex(digest: List[Int]) -> String
  digits = "0123456789abcdef"
  return digest.map do |b| digits.at(b / 16) + digits.at(b % 16) end.join("")
end

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

def main() -> Void
  dir: String = System.args()[0]
  empty = put_bytes(dir, "empty.bin", [])
  abc = put_bytes(dir, "abc.bin", [97, 98, 99])
  puts("empty #{hex(File.sha256(empty, 60000).unwrap!)}")
  puts("abc #{hex(File.sha256(abc, 60000).unwrap!)}")
  puts("digest agrees #{hex(File.sha256(abc, 60000).unwrap!) == hex(Digest.sha256([97, 98, 99]))}")
  puts("missing -> #{File.sha256(at(dir, "missing.bin"), 60000)}")
  puts("directory -> #{File.sha256(dir, 60000)}")
  puts("empty path -> #{File.sha256("", 60000)}")
  puts("zero timeout -> #{File.sha256(abc, 0)}")
  puts("negative timeout -> #{File.sha256(abc, -5)}")
end
