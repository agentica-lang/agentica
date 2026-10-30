# PBKDF2-HMAC-SHA256 on the two vectors of RFC 7914 §11 and scrypt on the first
# three of §12 (the fourth takes 1 GiB), then the errors: iterations below 1,
# lengths out of 1..1048576, a password or salt over 1048576 bytes, work over
# the caps (PBKDF2 iterations * ceil(length / 32) above 50000000, scrypt
# r * p * (n + 16) above 2^25), and scrypt parameters RFC 7914 or the memory
# cap refuses. Only ok? is printed for an error, never its text. tests/test_vm_crypto.py checks random inputs against
# Python's hashlib.
def shape(label: String, r: Result[Bytes]) -> Void
  puts("#{label} ok=#{r.ok?}")
end

def main() -> Void
  puts(Digest.hexencode(KDF.pbkdf2_hmac_sha256("passwd".bytes, "salt".bytes, 1, 64).unwrap!))
  puts(Digest.hexencode(KDF.pbkdf2_hmac_sha256("Password".bytes, "NaCl".bytes, 80000, 64).unwrap!))
  puts(Digest.hexencode(KDF.scrypt("".bytes, "".bytes, 16, 1, 1, 64).unwrap!))
  puts(Digest.hexencode(KDF.scrypt("password".bytes, "NaCl".bytes, 1024, 8, 16, 64).unwrap!))
  puts(Digest.hexencode(KDF.scrypt("pleaseletmein".bytes, "SodiumChloride".bytes, 16384, 8, 1, 64).unwrap!))
  # A shorter key is the start of a longer one, as both RFCs define.
  short = KDF.pbkdf2_hmac_sha256("passwd".bytes, "salt".bytes, 1, 20).unwrap!
  puts("prefix #{short == KDF.pbkdf2_hmac_sha256("passwd".bytes, "salt".bytes, 1, 64).unwrap!.take(20)}")
  pw = "pw".bytes
  salt = "salt".bytes
  big = Bytes.from_list(List.repeat(97, 1048576)).unwrap! + "a".bytes
  shape("iterations 0", KDF.pbkdf2_hmac_sha256(pw, salt, 0, 32))
  shape("iterations -1", KDF.pbkdf2_hmac_sha256(pw, salt, -1, 32))
  shape("length 0", KDF.pbkdf2_hmac_sha256(pw, salt, 1, 0))
  shape("length 1048577", KDF.pbkdf2_hmac_sha256(pw, salt, 1, 1048577))
  shape("password 1048577", KDF.pbkdf2_hmac_sha256(big, salt, 1, 32))
  shape("salt 1048577", KDF.scrypt(pw, big, 16, 1, 1, 32))
  shape("password 1048576", KDF.pbkdf2_hmac_sha256(big.drop(1), salt, 1, 32))
  shape("n 1", KDF.scrypt(pw, salt, 1, 1, 1, 32))
  shape("n 24", KDF.scrypt(pw, salt, 24, 1, 1, 32))
  shape("n 65536 r 1", KDF.scrypt(pw, salt, 65536, 1, 1, 32))
  shape("r 0", KDF.scrypt(pw, salt, 16, 0, 1, 32))
  shape("p 0", KDF.scrypt(pw, salt, 16, 1, 0, 32))
  shape("r p 2^30", KDF.scrypt(pw, salt, 2, 32768, 32768, 32))
  shape("memory 2 GiB", KDF.scrypt(pw, salt, 1048576, 16, 1, 32))
  shape("length 0 scrypt", KDF.scrypt(pw, salt, 16, 1, 1, 0))
  # The work caps refuse one step above 50000000 PBKDF2 rounds and above 2^25 for scrypt, before any work; a
  # large p with a small n counts too.
  shape("pbkdf2 rounds 50000001", KDF.pbkdf2_hmac_sha256(pw, salt, 50000001, 32))
  shape("pbkdf2 rounds 2 * 25000001", KDF.pbkdf2_hmac_sha256(pw, salt, 25000001, 33))
  shape("pbkdf2 iterations 10^12", KDF.pbkdf2_hmac_sha256(pw, salt, 1000000000000, 32))
  shape("scrypt work 2^25 + 16384", KDF.scrypt(pw, salt, 32768, 1, 1024, 32))
  shape("scrypt n 2 p 8000000", KDF.scrypt(pw, salt, 2, 1, 8000000, 32))
  shape("scrypt n 2^17 r 8 p 128", KDF.scrypt(pw, salt, 131072, 8, 128, 32))
end
