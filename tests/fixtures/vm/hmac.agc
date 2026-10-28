# HMAC-SHA256 and HMAC-SHA512 on the test cases 1 to 7 of RFC 4231 §4: case 5 is
# truncated to 128 bits there, so only its first 16 bytes are printed, and cases 6
# and 7 use a 131-byte key, longer than both block sizes. tests/test_vm_crypto.py
# checks generated keys and data against Python's hmac.
def both(label: String, key: List[Int], data: List[Int]) -> Void
  puts("#{label} sha256 #{HMAC.sha256_hexdigest(key, data)}")
  puts("#{label} sha512 #{HMAC.sha512_hexdigest(key, data)}")
end

# The byte form is the hex form decoded, with the MAC's size.
def bytes_agree(key: List[Int], data: List[Int]) -> Void
  same = (
    Digest.hexencode(HMAC.sha256(key, data)) == HMAC.sha256_hexdigest(key, data) and
    Digest.hexencode(HMAC.sha512(key, data)) == HMAC.sha512_hexdigest(key, data)
  )
  puts("bytes #{same} #{[HMAC.sha256(key, data).size, HMAC.sha512(key, data).size]}")
end

def main() -> Void
  both("1", List.repeat(11, 20), String.to_bytes("Hi There"))
  both("2", String.to_bytes("Jefe"), String.to_bytes("what do ya want for nothing?"))
  both("3", List.repeat(170, 20), List.repeat(221, 50))
  both("4", (1..25).to_a, List.repeat(205, 50))
  truncation = String.to_bytes("Test With Truncation")
  puts("5 sha256 #{Digest.hexencode(HMAC.sha256(List.repeat(12, 20), truncation).take(16))}")
  puts("5 sha512 #{Digest.hexencode(HMAC.sha512(List.repeat(12, 20), truncation).take(16))}")
  long_key = List.repeat(170, 131)
  both("6", long_key, String.to_bytes("Test Using Larger Than Block-Size Key - Hash Key First"))
  text = (
    "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be " +
    "hashed before being used by the HMAC algorithm."
  )
  both("7", long_key, String.to_bytes(text))
  bytes_agree([], [])
  bytes_agree(long_key, String.to_bytes("abc"))
end
