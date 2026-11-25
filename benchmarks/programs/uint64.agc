def scale() -> Int
  return 1
end

def checksum(rounds: Int) -> UInt64
  modulus = 4294967291.to_uint64!
  acc = 1.to_uint64!
  i = 0
  while i < rounds
    n = i.to_uint64!
    acc = (acc * 31.to_uint64! + n) % modulus
    if acc < n
      acc = acc + 1.to_uint64!
    end
    i += 1
  end
  acc
end

def main() -> Void
  rounds = 400000 * scale()
  puts("checksum #{rounds}: #{checksum(rounds)}")
end
