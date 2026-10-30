import Binary from "std/binary"

def scale() -> Int
  return 1
end

# 64 KiB of bytes from a linear congruential generator, so the data is the same on every run and in the Python twin.
def block() -> Bytes
  items: List[Int] = []
  x = 12345
  for _k in 0...65536
    x = (x * 1103515245 + 12345) % 2147483648
    items = items.push((x / 65536) % 256)
  end
  return Bytes.from_list(items).unwrap!
end

# Each 512 KiB part through gzip and back: the count of parts that came back equal.
def zlib_round_trip(data: Bytes) -> Int
  part = 524288
  same = 0
  at = 0
  while at < data.length
    piece = data.slice(at, part)
    packed = Zlib.gzip(piece, 6, 1048576).unwrap!
    if Zlib.gunzip(packed, 1048576).unwrap! == piece
      same += 1
    end
    at += part
  end
  return same
end

# The little-endian u32 at every fourth offset of the first `size` bytes, summed.
def binary_sum(data: Bytes, size: Int) -> Int
  total = 0
  at = 0
  while at < size
    total = (total + Binary.read_u32_le(data, at).unwrap!) % 1000000007
    at += 4
  end
  return total
end

# The data written to a file in 1 MiB writes and read back in 1 MiB reads: the SHA-256 of what came back.
def file_round_trip(data: Bytes, path: String) -> String
  chunk = 1048576
  out = File.open(path, "write").unwrap!
  at = 0
  while at < data.length
    File.write_bytes(out, data.slice(at, chunk)).unwrap!
    at += chunk
  end
  File.close(out).unwrap!
  input = File.open(path, "read").unwrap!
  parts: List[Bytes] = []
  more = true
  while more
    piece = File.read_bytes(input, chunk).unwrap!
    parts = parts.push(piece)
    more = piece.length > 0
  end
  File.close(input).unwrap!
  Path.remove(path).unwrap!
  return Digest.sha256_hexdigest(Bytes.concat(parts))
end

def main() -> Void
  mib = 4 * scale()
  data = Bytes.concat(List.repeat(block(), 16 * mib))
  digest = Digest.sha256_hexdigest(data)
  same = zlib_round_trip(data)
  sum = binary_sum(data, 1048576 * scale())
  directory = System.env("TMPDIR").unwrap_or("/tmp")
  path = Path.join([directory, "agentica-bench-bytes-#{System.pid}.bin"]).unwrap!
  read_back = file_round_trip(data, path)
  puts("bytes #{mib}: checksum #{digest.slice(0, 16)} #{same} #{sum} #{read_back == digest}")
end
