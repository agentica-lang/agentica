# Reads a JSON Cases document on stdin and prints, as JSON, the AES-256-GCM
# encryption of each case (the ciphertext with the tag appended) and the
# decryption of the case's sealed bytes, which tests/fixtures/gcm-peer.js
# sealed; tests/test_vm_crypto.py compares both with that Node peer. Bytes go
# in and out as hex.
struct Case
  key: String
  iv: String
  aad: String
  data: String
  sealed: String
end

struct Cases
  cases: List[Case]
end

struct Out
  sealed: String
  opened: String
end

def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  outs = cases.map do |c: Case|
    key = hex(c.key)
    iv = hex(c.iv)
    aad = hex(c.aad)
    Out(
      sealed: Digest.hexencode(Cipher.aes_256_gcm_encrypt(key, iv, hex(c.data), aad).unwrap!),
      opened: Digest.hexencode(Cipher.aes_256_gcm_decrypt(key, iv, hex(c.sealed), aad).unwrap!),
    )
  end
  puts(JSON.encode(outs))
end
