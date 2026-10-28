# SecureRandom gives new bytes on every run, so this prints only properties:
# sizes, the byte range, lowercase hex of 2n digits, the 8-4-4-4-12 form of
# uuid with its version 4 and variant 10xx digits, and that two draws differ (16
# random bytes repeat with chance 2 ** -128). tests/test_vm_crypto.py checks
# many more draws against Python's uuid.
def bytes?(data: List[Int]) -> Bool
  return data.all? do |b: Int| b >= 0 and b <= 255 end
end

def hex?(text: String) -> Bool
  return text.split("").all? do |c: String| "0123456789abcdef".include?(c) end
end

def uuid?(text: String) -> Bool
  parts = text.split("-")
  sizes = parts.map do |part: String| part.size.to_s end
  shape = text.size == 36 and sizes.join(" ") == "8 4 4 4 12" and hex?(parts.join(""))
  return shape and String.slice(text, 14, 1) == "4" and "89ab".include?(String.slice(text, 19, 1))
end

def main() -> Void
  for n in [0, 1, 16, 4096]
    data = SecureRandom.random_bytes(n)
    hex = SecureRandom.hex(n)
    puts("#{n} #{data.size} #{bytes?(data)} #{hex.size} #{hex?(hex)}")
  end
  puts("default #{SecureRandom.random_bytes.size} #{SecureRandom.hex.size}")
  puts(Digest.hexencode(SecureRandom.random_bytes(16)) != Digest.hexencode(SecureRandom.random_bytes(16)))
  puts(SecureRandom.hex(16) != SecureRandom.hex(16))
  first = SecureRandom.uuid
  puts("#{uuid?(first)} #{uuid?(SecureRandom.uuid())} #{first != SecureRandom.uuid}")
end
