# Reads a JSON Cases document on stdin and prints, as JSON, the
# HMAC-SHA256 and HMAC-SHA512 of each case as bytes and as hex;
# tests/test_vm_crypto.py compares them with Python's hmac.
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
    Macs(
      sha256: HMAC.sha256(c.key, c.data),
      sha256_hex: HMAC.sha256_hexdigest(c.key, c.data),
      sha512: HMAC.sha512(c.key, c.data),
      sha512_hex: HMAC.sha512_hexdigest(c.key, c.data),
    )
  end
  puts(JSON.encode(macs))
end
