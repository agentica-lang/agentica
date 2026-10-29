# The Digest hashes on the known-answer vectors of RFC 1321 §A.5 (MD5), RFC 3174 §7.3 (SHA-1) and FIPS 180-4 / the NIST
# examples (SHA-256, SHA-512), with the one million "a" case; tests/test_vm_crypto.py checks generated inputs against
# Python's hashlib.
def all_hex(label: String, data: Bytes) -> Void
  puts("#{label} md5 #{Digest.md5_hexdigest(data)}")
  puts("#{label} sha1 #{Digest.sha1_hexdigest(data)}")
  puts("#{label} sha256 #{Digest.sha256_hexdigest(data)}")
  puts("#{label} sha512 #{Digest.sha512_hexdigest(data)}")
end

# The byte form is the hex form decoded, with the digest's size.
def bytes_agree(data: Bytes) -> Void
  same = (
    Digest.hexencode(Digest.md5(data)) == Digest.md5_hexdigest(data) and
    Digest.hexencode(Digest.sha1(data)) == Digest.sha1_hexdigest(data) and
    Digest.hexencode(Digest.sha256(data)) == Digest.sha256_hexdigest(data) and
    Digest.hexencode(Digest.sha512(data)) == Digest.sha512_hexdigest(data)
  )
  sizes = [Digest.md5(data).size, Digest.sha1(data).size, Digest.sha256(data).size, Digest.sha512(data).size]
  puts("bytes #{same} #{sizes}")
end

def main() -> Void
  all_hex("empty", "".bytes)
  all_hex("abc", "abc".bytes)
  puts("md5 a #{Digest.md5_hexdigest("a".bytes)}")
  puts("md5 message #{Digest.md5_hexdigest("message digest".bytes)}")
  puts("md5 alphabet #{Digest.md5_hexdigest("abcdefghijklmnopqrstuvwxyz".bytes)}")
  mixed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  puts("md5 mixed #{Digest.md5_hexdigest(mixed.bytes)}")
  digits = List.repeat("1234567890", 8).join("")
  puts("md5 digits #{Digest.md5_hexdigest(digits.bytes)}")
  two_blocks = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".bytes
  puts("448 sha1 #{Digest.sha1_hexdigest(two_blocks)}")
  puts("448 sha256 #{Digest.sha256_hexdigest(two_blocks)}")
  repeated = List.repeat("0123456701234567012345670123456701234567012345670123456701234567", 10).join("")
  puts("sha1 repeated #{Digest.sha1_hexdigest(repeated.bytes)}")
  long = (
    "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrst" +
    "nopqrstu"
  )
  puts("896 sha512 #{Digest.sha512_hexdigest(long.bytes)}")
  all_hex("million", List.repeat("a", 1000000).join("").bytes)
  bytes_agree("".bytes)
  bytes_agree("abc".bytes)
  # Two digests compare with ==; HMAC.secure_compare is the constant-time compare for a secret.
  abc = Digest.sha256("abc".bytes)
  puts("equal #{abc == Digest.sha256("abc".bytes)} #{abc == Digest.sha256("abd".bytes)}")
end
