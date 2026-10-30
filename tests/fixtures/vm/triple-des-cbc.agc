# Triple DES CBC on NIST CAVP vectors (TCBCMMT3: three keys, encrypt and
# decrypt; TCBCMMT2: two keys, K1 K2 K1, given as the 16 bytes K1 K2), then
# the errors: a key of another size, an iv of another size and data that is
# not whole 8-byte blocks. tests/test_vm_crypto.py checks random inputs
# against a Node peer.
def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def encrypt(label: String, key: String, iv: String, plain: String) -> Void
  cipher = Cipher.des_ede3_cbc_encrypt(hex(key), hex(iv), hex(plain)).unwrap!
  back = Cipher.des_ede3_cbc_decrypt(hex(key), hex(iv), cipher).unwrap!
  puts("#{label} #{Digest.hexencode(cipher)} #{back == hex(plain)}")
end

def decrypt(label: String, key: String, iv: String, cipher: String) -> Void
  plain = Cipher.des_ede3_cbc_decrypt(hex(key), hex(iv), hex(cipher)).unwrap!
  puts("#{label} #{Digest.hexencode(plain)}")
end

def shape(label: String, r: Result[Bytes]) -> Void
  puts("#{label} ok=#{r.ok?}")
end

def main() -> Void
  encrypt(
    "mmt3 encrypt 0",
    "46133dcbf232b51964e0d95e83208f156732bf75b673abf1",
    "34814c87f47fd59d",
    "de655a0ea771436c",
  )
  encrypt(
    "mmt3 encrypt 3",
    "202398b6154968c168201329910e612f296189d320670120",
    "514273c93806fde6",
    "9a5ec913876299492dda3998f88e1c31a75493b3ade14e9ed7de1f0a303f0299",
  )
  decrypt(
    "mmt3 decrypt 4",
    "cbda4a4cbcb0fdd6c4c4d0b06be085b092abdc07bcb56ba7",
    "47626f9fb95ccfcc",
    "db48b63d6331b747621d73cfd3efd4690b7302ee91e7d71e2fba948a4993d2b26e95bb6a2de27982",
  )
  decrypt(
    "mmt2 decrypt 3",
    "160b70ad26e60e8a1adadcc240619ec2",
    "200e89b4097ef967",
    "50e5c5bcc3d84c47fed29ce4caccd5fc7724f56615f8ade5e7d26df2148bc2bc",
  )
  # The 16-byte key is the same cipher as K1 K2 K1 in 24 bytes.
  k1 = "160b70ad26e60e8a"
  k2 = "1adadcc240619ec2"
  data = "5ac6533b1de8edd31224a91f7361dc2b".bytes
  two = Cipher.des_ede3_cbc_encrypt(hex(k1 + k2), hex("200e89b4097ef967"), data).unwrap!
  three = Cipher.des_ede3_cbc_encrypt(hex(k1 + k2 + k1), hex("200e89b4097ef967"), data).unwrap!
  puts("two-key #{two == three}")
  key = hex("46133dcbf232b51964e0d95e83208f156732bf75b673abf1")
  iv = hex("34814c87f47fd59d")
  empty = Cipher.des_ede3_cbc_encrypt(key, iv, "".bytes).unwrap!
  puts("empty #{empty.size}")
  shape("key 8", Cipher.des_ede3_cbc_encrypt(key.take(8), iv, "12345678".bytes))
  shape("key 32", Cipher.des_ede3_cbc_decrypt(key + key.take(8), iv, "12345678".bytes))
  shape("iv 7", Cipher.des_ede3_cbc_encrypt(key, iv.take(7), "12345678".bytes))
  shape("iv 16", Cipher.des_ede3_cbc_decrypt(key, iv + iv, "12345678".bytes))
  shape("data 7", Cipher.des_ede3_cbc_encrypt(key, iv, "1234567".bytes))
  shape("data 9", Cipher.des_ede3_cbc_decrypt(key, iv, "123456789".bytes))
end
