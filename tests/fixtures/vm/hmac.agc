# HMAC-SHA256 and HMAC-SHA512 on the test cases 1 to 7 of RFC 4231 §4: case 5 is
# truncated to 128 bits there, so only its first 16 bytes are printed, and cases 6
# and 7 use a 131-byte key, longer than both block sizes. tests/test_vm_crypto.py
# checks generated keys and data against Python's hmac.
def both(label: String, key: Bytes, data: Bytes) -> Void
  puts("#{label} sha256 #{HMAC.sha256_hexdigest(key, data)}")
  puts("#{label} sha512 #{HMAC.sha512_hexdigest(key, data)}")
end

# The byte form is the hex form decoded, with the MAC's size.
def bytes_agree(key: Bytes, data: Bytes) -> Void
  same = (
    Digest.hexencode(HMAC.sha256(key, data)) == HMAC.sha256_hexdigest(key, data) and
    Digest.hexencode(HMAC.sha512(key, data)) == HMAC.sha512_hexdigest(key, data)
  )
  puts("bytes #{same} #{[HMAC.sha256(key, data).size, HMAC.sha512(key, data).size]}")
end

def repeat(byte: Int, n: Int) -> Bytes
  return Bytes.from_list(List.repeat(byte, n)).unwrap!
end

def main() -> Void
  both("1", repeat(11, 20), "Hi There".bytes)
  both("2", "Jefe".bytes, "what do ya want for nothing?".bytes)
  both("3", repeat(170, 20), repeat(221, 50))
  both("4", Bytes.from_list((1..25).to_a).unwrap!, repeat(205, 50))
  truncation = "Test With Truncation".bytes
  puts("5 sha256 #{Digest.hexencode(HMAC.sha256(repeat(12, 20), truncation).take(16))}")
  puts("5 sha512 #{Digest.hexencode(HMAC.sha512(repeat(12, 20), truncation).take(16))}")
  long_key = repeat(170, 131)
  both("6", long_key, "Test Using Larger Than Block-Size Key - Hash Key First".bytes)
  text = (
    "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be " +
    "hashed before being used by the HMAC algorithm."
  )
  both("7", long_key, text.bytes)
  bytes_agree("".bytes, "".bytes)
  bytes_agree(long_key, "abc".bytes)
end
