# Reads all of stdin as bytes and prints Crypto.sha256 of them as a list; tests/test_vm_crypto.py compares it with
# Python's hashlib.
def main() -> Void
  data: List[Int] = []
  chunk = IO.read_bytes(1048576).unwrap!
  while chunk.size > 0
    data = data.concat(chunk)
    chunk = IO.read_bytes(1048576).unwrap!
  end
  puts(Crypto.sha256(data))
end
