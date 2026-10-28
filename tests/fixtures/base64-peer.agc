# Reads a JSON Cases document on stdin and prints, as JSON, every Base64 and hex
# form of each byte list and every decode of each text; tests/test_vm_crypto.py
# compares the answers with Python's base64 and binascii. A decode that fails is
# null.
struct Cases
  bytes: List[List[Int]]
  texts: List[String]
end

struct Decoded
  lenient: List[Int]
  strict: JsonField[List[Int]]
  urlsafe: JsonField[List[Int]]
  hex: JsonField[List[Int]]
end

struct Answers
  encoded: List[List[String]]
  decoded: List[Decoded]
end

def field(result: Result[List[Int]]) -> JsonField[List[Int]]
  case result
    ok(bytes) -> return JsonField.Value(bytes)
    error(_) -> return JsonField.Null
  end
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!
  encoded = cases.bytes.map do |data: List[Int]|
    [
      Base64.encode64(data), Base64.strict_encode64(data), Base64.urlsafe_encode64(data),
      Base64.urlsafe_encode64(data, false), Digest.hexencode(data),
    ]
  end
  decoded = cases.texts.map do |text: String|
    Decoded(
      lenient: Base64.decode64(text),
      strict: field(Base64.strict_decode64(text)),
      urlsafe: field(Base64.urlsafe_decode64(text)),
      hex: field(Digest.hexdecode(text)),
    )
  end
  puts(JSON.encode(Answers(encoded: encoded, decoded: decoded)))
end
