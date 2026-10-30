# CMAC on the examples of NIST SP 800-38B appendix D: AES-128, -192 and -256
# with messages of 0, 16, 40 and 64 bytes, and Triple DES with three keys and
# with two keys (given as the 16 bytes K1 K2) on messages of 0, 8, 20 and 32
# bytes. Then the errors: keys of other sizes. tests/test_vm_crypto.py checks
# random inputs against a Node peer.
MESSAGE = (
  "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51" +
  "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
)

def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def aes(label: String, key: String) -> Void
  tags = [0, 16, 40, 64].map do |n: Int|
    Digest.hexencode(CMAC.aes(hex(key), hex(MESSAGE).take(n)).unwrap!)
  end
  puts("#{label} #{tags.join(" ")}")
end

def des_ede3(label: String, key: String) -> Void
  tags = [0, 8, 20, 32].map do |n: Int|
    Digest.hexencode(CMAC.des_ede3(hex(key), hex(MESSAGE).take(n)).unwrap!)
  end
  puts("#{label} #{tags.join(" ")}")
end

def shape(label: String, r: Result[Bytes]) -> Void
  puts("#{label} ok=#{r.ok?}")
end

def main() -> Void
  aes("aes-128", "2b7e151628aed2a6abf7158809cf4f3c")
  aes("aes-192", "8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b")
  aes("aes-256", "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
  des_ede3("tdea-3", "8aa83bf8cbda10620bc1bf19fbb6cd58bc313d4a371ca8b5")
  des_ede3("tdea-2", "4cf15134a2850dd58a3d10ba80570d38")
  key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
  data = "data".bytes
  shape("aes key 0", CMAC.aes("".bytes, data))
  shape("aes key 15", CMAC.aes(key.take(15), data))
  shape("aes key 33", CMAC.aes(key + key.take(1), data))
  shape("tdea key 8", CMAC.des_ede3(key.take(8), data))
  shape("tdea key 32", CMAC.des_ede3(key, data))
  # A received tag is checked in constant time.
  tag = CMAC.aes(key.take(16), data).unwrap!
  puts("check #{HMAC.secure_compare(tag, CMAC.aes(key.take(16), data).unwrap!)}")
end
