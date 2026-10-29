# HMAC.secure_compare on known answers: equal values, values that differ in the
# first, a middle or the last byte, values of other lengths (a prefix, empty
# against one byte) and the check of a received HMAC-SHA256 (RFC 4231 §4.2).
# tests/test_vm_crypto.py checks generated pairs against Python's
# hmac.compare_digest.
def check(label: String, a: Bytes, b: Bytes) -> Void
  puts("#{label} #{HMAC.secure_compare(a, b)} #{HMAC.secure_compare(b, a)}")
end

def bytes(items: List[Int]) -> Bytes
  return Bytes.from_list(items).unwrap!
end

def main() -> Void
  token = bytes((0..31).to_a)
  check("same", token, bytes((0..31).to_a))
  check("empty", "".bytes, "".bytes)
  check("first", token, bytes([255]) + token.drop(1))
  check("middle", token, token.take(16) + bytes([0]) + token.drop(17))
  check("last", token, token.take(31) + bytes([0]))
  check("prefix", token, token.take(31))
  check("one", "".bytes, bytes([0]))
  check("zeros", bytes([0]), bytes([0, 0]))
  key = bytes(List.repeat(11, 20))
  mac = HMAC.sha256(key, "Hi There".bytes)
  received = Digest.hexdecode("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7").unwrap!
  check("rfc4231", mac, received)
  check("forged", mac, HMAC.sha256(key, "Hi there".bytes))
end
