# Reads a JSON Cases document on stdin and prints, as JSON, Triple DES CBC
# (encrypt and decrypt of the whole blocks) and the AES and Triple DES CMACs
# of each case; tests/test_vm_crypto.py compares them with
# tests/fixtures/cipher-peer.js. Bytes go in and out as hex.
struct Case
  des_key: String
  iv: String
  aes_key: String
  blocks: String
  data: String
end

struct Cases
  cases: List[Case]
end

struct Out
  encrypt: String
  decrypt: String
  cmac_aes: String
  cmac_des_ede3: String
end

def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  outs = cases.map do |c: Case|
    des_key = hex(c.des_key)
    iv = hex(c.iv)
    blocks = hex(c.blocks)
    data = hex(c.data)
    Out(
      encrypt: Digest.hexencode(Cipher.des_ede3_cbc_encrypt(des_key, iv, blocks).unwrap!),
      decrypt: Digest.hexencode(Cipher.des_ede3_cbc_decrypt(des_key, iv, blocks).unwrap!),
      cmac_aes: Digest.hexencode(CMAC.aes(hex(c.aes_key), data).unwrap!),
      cmac_des_ede3: Digest.hexencode(CMAC.des_ede3(des_key, data).unwrap!),
    )
  end
  puts(JSON.encode(outs))
end
