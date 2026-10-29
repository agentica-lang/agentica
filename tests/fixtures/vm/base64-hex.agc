# Base64 and hex on the RFC 4648 §10 vectors and on the edges of each Ruby form:
# the 60-character lines of encode64, the padding of the urlsafe forms, what
# decode64 skips and where it stops, and what the strict forms reject.
# tests/test_vm_crypto.py checks generated inputs against Python's base64.
def text(bytes: Bytes) -> String
  return String.from_bytes(bytes.to_a).unwrap!
end

def bytes(items: List[Int]) -> Bytes
  return Bytes.from_list(items).unwrap!
end

def main() -> Void
  vectors = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
  for word in vectors
    data = word.bytes
    strict = Base64.strict_encode64(data)
    hex = Digest.hexencode(data)
    back = text(Base64.strict_decode64(strict).unwrap!)
    upper = Digest.hexdecode(hex.upcase).unwrap! == data
    puts("#{word.inspect} #{strict} #{Base64.encode64(data).inspect} #{hex} #{back == word} #{upper}")
  end
  puts(Base64.encode64(bytes(List.repeat(0, 45))).inspect)
  puts(Base64.encode64(bytes(List.repeat(0, 46))).inspect)
  puts(Base64.urlsafe_encode64(bytes([251, 255])))
  puts(Base64.urlsafe_encode64(bytes([251, 255]), false))
  puts(Base64.urlsafe_encode64(bytes([251]), false))
  puts(Base64.strict_encode64(bytes([251, 255])))
  puts(Base64.decode64("Zm9v YmFy\n").to_a)
  puts(Base64.decode64("Zm9vYmE").to_a)
  puts(Base64.decode64("Zh").to_a)
  puts(Base64.decode64("Z").to_a)
  puts(Base64.decode64("=Zg").to_a)
  puts(Base64.decode64("Zm9=YmFy").to_a)
  puts(Base64.decode64("Zg==Zm9v").to_a)
  puts(Base64.decode64("!!é").to_a)
  puts(Base64.decode64("Zm9v").inspect)
  for bad in ["Zg", "Zg=", "Zh==", "Zm9v\n", "Zg==Zg==", "Zm=v", "Z===", "-_8=", "é"]
    puts("strict #{bad.inspect} #{Base64.strict_decode64(bad)}")
  end
  for url in ["", "Zg", "Zg==", "-_8", "+/8=", "Z", "Zg=", "Zm9v\n"]
    puts("urlsafe #{url.inspect} #{Base64.urlsafe_decode64(url)}")
  end
  for hex in ["", "abc", "0x00", "zz", "é", "00 ", "FFfe"]
    puts("hex #{hex.inspect} #{Digest.hexdecode(hex)}")
  end
end
