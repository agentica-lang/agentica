# Reads all of stdin as bytes and prints, for MD5, SHA-1, SHA-256 and SHA-512 in that order, the digest as a list and
# then its hex form, one per line; tests/test_vm_crypto.py compares them with Python's hashlib.
def main() -> Void
  items: List[Int] = []
  chunk = IO.read_bytes(1048576).unwrap!
  while chunk.size > 0
    items = items.concat(chunk)
    chunk = IO.read_bytes(1048576).unwrap!
  end
  data = Bytes.from_list(items).unwrap!
  puts(Digest.md5(data).to_a)
  puts(Digest.md5_hexdigest(data))
  puts(Digest.sha1(data).to_a)
  puts(Digest.sha1_hexdigest(data))
  puts(Digest.sha256(data).to_a)
  puts(Digest.sha256_hexdigest(data))
  puts(Digest.sha512(data).to_a)
  puts(Digest.sha512_hexdigest(data))
end
