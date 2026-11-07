# Reads a JSON Cases document on stdin and prints, as JSON, the RSA-OAEP
# encryption of each case's data with the case's PEM public key;
# tests/test_vm_crypto.py has tests/fixtures/rsa-peer.js decrypt them with the
# private key. Bytes go in and out as hex.
struct Case
  pem: String
  data: String
end

struct Cases
  cases: List[Case]
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  sealed = cases.map do |c: Case|
    Digest.hexencode(RSA.public_encrypt_oaep(c.pem, Digest.hexdecode(c.data).unwrap!).unwrap!)
  end
  puts(JSON.encode(sealed))
end
