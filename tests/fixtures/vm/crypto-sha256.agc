# Crypto.sha256 on short known inputs; tests/test_vm_crypto.py checks long ones against hashlib.
def hex(digest: List[Int]) -> String
  digits = "0123456789abcdef"
  return digest.map do |b| digits.at(b / 16) + digits.at(b % 16) end.join("")
end

def main() -> Void
  puts(hex(Crypto.sha256([])))
  puts(hex(Crypto.sha256([97, 98, 99])))
  digest = Crypto.sha256(List.repeat(0, 64))
  puts(digest.size)
  puts(hex(digest))
end
