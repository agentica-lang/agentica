# Reads a JSON Draws document on stdin and prints, as JSON, the
# OpenSSL.Random.random_bytes and OpenSSL.Random.hex of each size and the given
# number of OpenSSL.Random.uuid draws; tests/test_vm_crypto.py checks their
# formats with Python's uuid and re. JSON has no byte type, so the bytes go out
# as lists of Ints.
struct Draws
  sizes: List[Int]
  uuids: Int
end

struct Drawn
  bytes: List[List[Int]]
  hex: List[String]
  uuids: List[String]
end

def main() -> Void
  draws = JSON.decode(IO.read(), Draws).unwrap!
  bytes = draws.sizes.map do |n: Int| OpenSSL.Random.random_bytes(n).to_a end
  hex = draws.sizes.map do |n: Int| OpenSSL.Random.hex(n) end
  uuids = (0...draws.uuids).to_a.map do |_: Int| OpenSSL.Random.uuid end
  puts(JSON.encode(Drawn(bytes: bytes, hex: hex, uuids: uuids)))
end
