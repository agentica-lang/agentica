# Reads a JSON Cases document on stdin and prints, as JSON, the
# HMAC-SHA256 and HMAC-SHA512 of each case as bytes and as hex;
# tests/test_vm_crypto.py compares them with Python's hmac. JSON has no byte
# type, so bytes go in and out as lists of Ints.
struct Case
  key: List[Int]
  data: List[Int]
end

struct Cases
  cases: List[Case]
end

struct Macs
  sha256: List[Int]
  sha256_hex: String
  sha512: List[Int]
  sha512_hex: String
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  macs = cases.map do |c: Case|
    key = Bytes.from_list(c.key).unwrap!
    data = Bytes.from_list(c.data).unwrap!
    Macs(
      sha256: HMAC.sha256(key, data).to_a,
      sha256_hex: HMAC.sha256_hexdigest(key, data),
      sha512: HMAC.sha512(key, data).to_a,
      sha512_hex: HMAC.sha512_hexdigest(key, data),
    )
  end
  puts(JSON.encode(macs))
end
