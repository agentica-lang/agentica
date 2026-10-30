# PBKDF2-HMAC-SHA256 on the two vectors of RFC 7914 §11 and scrypt on the first
# three of §12 (the fourth takes 1 GiB), then the errors: iterations below 1,
# lengths out of 1..1048576, a password or salt over 1048576 bytes, and scrypt
# parameters RFC 7914 or the memory cap refuses. Only ok? is printed for an
# error, never its text. tests/test_vm_crypto.py checks random inputs against
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
end
