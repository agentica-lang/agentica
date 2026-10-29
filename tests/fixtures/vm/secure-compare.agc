# HMAC.secure_compare on known answers: equal lists, lists that differ in the
# first, a middle or the last byte, lists of other lengths (a prefix, empty
# against one byte) and the check of a received HMAC-SHA256 (RFC 4231 §4.2).
# tests/test_vm_crypto.py checks generated pairs against Python's
# hmac.compare_digest.
def check(label: String, a: List[Int], b: List[Int]) -> Void
  puts("#{label} #{HMAC.secure_compare(a, b)} #{HMAC.secure_compare(b, a)}")
end

def main() -> Void
  token = (0..31).to_a
  check("same", token, (0..31).to_a)
  check("empty", [], [])
  check("first", token, [255].concat(token.drop(1)))
  check("middle", token, token.take(16).concat([0]).concat(token.drop(17)))
  check("last", token, token.take(31).concat([0]))
  check("prefix", token, token.take(31))
  check("one", [], [0])
  check("zeros", [0], [0, 0])
  key = List.repeat(11, 20)
  mac = HMAC.sha256(key, String.to_bytes("Hi There"))
  received = Digest.hexdecode("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7").unwrap!
  check("rfc4231", mac, received)
  check("forged", mac, HMAC.sha256(key, String.to_bytes("Hi there")))
end
