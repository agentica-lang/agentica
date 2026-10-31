# Reads a JSON Cases document on stdin and prints, as JSON, the answer of
# Bytes.decode or String.encode for each case; tests/test_vm_text_codecs.py
# compares them with Python's bytes.decode and str.encode. JSON has no byte
# type, so the bytes come and go as lists of Ints.
struct Case
  op: String
  encoding: String
  data: List[Int]
  text: String
end

struct Cases
  cases: List[Case]
end

struct Answer
  passed: Bool
  data: List[Int]
  text: String
  message: String
end

def answer(c: Case) -> Answer
  if c.op == "decode"
    case Bytes.from_list(c.data).unwrap!.decode(c.encoding)
      ok(text) -> return Answer(passed: true, data: [], text: text, message: "")
      error(message) -> return Answer(passed: false, data: [], text: "", message: message)
    end
  end

  case c.text.encode(c.encoding)
    ok(bytes) -> return Answer(passed: true, data: bytes.to_a, text: "", message: "")
    error(message) -> return Answer(passed: false, data: [], text: "", message: message)
  end
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  puts(JSON.encode(cases.map do |c: Case| answer(c) end))
end
