# AES-256-GCM on test cases 13 to 16 of the GCM specification (McGrew and
# Viega, the AES-256 cases with a 96-bit IV): each is sealed, which gives the
# ciphertext with the tag appended, and opened again. Then auth_data left out
# is the empty one, a tampered tag, ciphertext, auth_data, key or iv fails to
# open, and keys, ivs and inputs of other sizes are errors. Only ok? is printed
# for an error, never its text. tests/test_vm_crypto.py checks random inputs
# against a Node peer.
KEY = "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"
IV = "cafebabefacedbaddecaf888"
PLAIN = (
  "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
  "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
)
AAD = "feedfacedeadbeeffeedfacedeadbeefabaddad2"

def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def seal(label: String, key: String, iv: String, plain: Bytes, aad: String) -> Void
  sealed = Cipher.aes_256_gcm_encrypt(hex(key), hex(iv), plain, hex(aad)).unwrap!
  opened = Cipher.aes_256_gcm_decrypt(hex(key), hex(iv), sealed, hex(aad)).unwrap!
  puts("#{label} #{Digest.hexencode(sealed)} #{opened == plain}")
end

# The bytes with the one at index flipped in its lowest bit.
def flip(data: Bytes, index: Int) -> Bytes
  return data.take(index) + Bytes.from_list([Int.bit_xor(data[index], 1)]).unwrap! + data.drop(index + 1)
end

def shape(label: String, r: Result[Bytes]) -> Void
  puts("#{label} ok=#{r.ok?}")
end

def main() -> Void
  zero_key = Digest.hexencode(Bytes.from_list(List.repeat(0, 32)).unwrap!)
  zero_iv = "000000000000000000000000"
  seal("tc13", zero_key, zero_iv, "".bytes, "")
  seal("tc14", zero_key, zero_iv, Bytes.from_list(List.repeat(0, 16)).unwrap!, "")
  seal("tc15", KEY, IV, hex(PLAIN), "")
  seal("tc16", KEY, IV, hex(PLAIN).take(60), AAD)
  key = hex(KEY)
  iv = hex(IV)
  plain = hex(PLAIN).take(60)
  aad = hex(AAD)
  left_out = Cipher.aes_256_gcm_encrypt(key, iv, plain).unwrap!
  puts("default #{left_out == Cipher.aes_256_gcm_encrypt(key, iv, plain, "".bytes).unwrap!}")
  sealed = Cipher.aes_256_gcm_encrypt(key, iv, plain, aad).unwrap!
  shape("tag flipped", Cipher.aes_256_gcm_decrypt(key, iv, flip(sealed, sealed.size - 1), aad))
  shape("tag cut", Cipher.aes_256_gcm_decrypt(key, iv, sealed.take(sealed.size - 1), aad))
  shape("ciphertext flipped", Cipher.aes_256_gcm_decrypt(key, iv, flip(sealed, 0), aad))
  shape("auth_data flipped", Cipher.aes_256_gcm_decrypt(key, iv, sealed, flip(aad, 3)))
  shape("auth_data left out", Cipher.aes_256_gcm_decrypt(key, iv, sealed))
  shape("key flipped", Cipher.aes_256_gcm_decrypt(flip(key, 31), iv, sealed, aad))
  shape("iv flipped", Cipher.aes_256_gcm_decrypt(key, flip(iv, 11), sealed, aad))
  shape("key 31", Cipher.aes_256_gcm_encrypt(key.take(31), iv, plain))
  shape("key 33", Cipher.aes_256_gcm_encrypt(key + key.take(1), iv, plain))
  shape("key 16", Cipher.aes_256_gcm_decrypt(key.take(16), iv, sealed))
  shape("iv 0", Cipher.aes_256_gcm_encrypt(key, "".bytes, plain))
  shape("iv 11", Cipher.aes_256_gcm_encrypt(key, iv.take(11), plain))
  shape("iv 16", Cipher.aes_256_gcm_decrypt(key, iv + iv.take(4), sealed))
  shape("input 0", Cipher.aes_256_gcm_decrypt(key, iv, "".bytes))
  shape("input 15", Cipher.aes_256_gcm_decrypt(key, iv, sealed.take(15)))
end
