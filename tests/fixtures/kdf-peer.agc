# Reads a JSON Cases document on stdin and prints, as JSON, PBKDF2-HMAC-SHA256
# and scrypt of each case; tests/test_vm_crypto.py compares them with Python's
# hashlib.pbkdf2_hmac and hashlib.scrypt. Bytes go in and out as hex.
struct Case
  password: String
  salt: String
  iterations: Int
  n: Int
  r: Int
  p: Int
  length: Int
end

struct Cases
  cases: List[Case]
end

struct Out
  pbkdf2: String
  scrypt: String
end

def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  outs = cases.map do |c: Case|
    password = hex(c.password)
    salt = hex(c.salt)
    Out(
      pbkdf2: Digest.hexencode(KDF.pbkdf2_hmac_sha256(password, salt, c.iterations, c.length).unwrap!),
      scrypt: Digest.hexencode(KDF.scrypt(password, salt, c.n, c.r, c.p, c.length).unwrap!),
    )
  end
  puts(JSON.encode(outs))
end
