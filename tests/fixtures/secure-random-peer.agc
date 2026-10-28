# Reads a JSON Draws document on stdin and prints, as JSON, the
# SecureRandom.random_bytes and SecureRandom.hex of each size and the given
# number of SecureRandom.uuid draws; tests/test_vm_crypto.py checks their
# formats with Python's uuid and re.
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
  bytes = draws.sizes.map do |n: Int| SecureRandom.random_bytes(n) end
  hex = draws.sizes.map do |n: Int| SecureRandom.hex(n) end
  uuids = (0...draws.uuids).to_a.map do |_: Int| SecureRandom.uuid end
  puts(JSON.encode(Drawn(bytes: bytes, hex: hex, uuids: uuids)))
end
