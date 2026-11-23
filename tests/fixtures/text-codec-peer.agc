# Reads a JSON Cases document on stdin and prints, as JSON, the answer of
# Bytes.decode, Bytes.scrub or String.encode for each case (scrub replaces
# with text, "default" for U+FFFD; stream scrubs the data in chunks of size bytes,
# keeping the bytes that incomplete_utf8_length counts for the next chunk); tests/test_vm_text_codecs.py
# compares them with Python's bytes.decode and str.encode. JSON has no byte
# type, so the bytes come and go as lists of Ints.
struct Case
  op: String
  encoding: String
  data: List[Int]
  text: String
  size: Int
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

def stream_scrub(data: Bytes, size: Int) -> String
  text = ""
  carry = Bytes.from_list([]).unwrap!
  at = 0
  while at < data.length
    chunk = carry + data.slice(at, [size, data.length - at].min.unwrap!)
    at += size
    kept = chunk.incomplete_utf8_length
    text += chunk.take(chunk.length - kept).scrub
    carry = chunk.drop(chunk.length - kept)
  end
  return text + carry.scrub
end

def answer(c: Case) -> Answer
  if c.op == "stream"
    text = stream_scrub(Bytes.from_list(c.data).unwrap!, c.size)
    return Answer(passed: true, data: [], text: text, message: "")
  end
  if c.op == "scrub"
    data = Bytes.from_list(c.data).unwrap!
    if c.text == "default"
      return Answer(passed: true, data: [], text: data.scrub, message: "")
    end
    return Answer(passed: true, data: [], text: data.scrub(c.text), message: "")
  end
  if c.op == "decode"
    case Bytes.from_list(c.data).unwrap!.decode(c.encoding)
      ok(text) -> return Answer(passed: true, data: [], text: text, message: "")
      error(e) -> return Answer(passed: false, data: [], text: "", message: e.message)
    end
  end

  case c.text.encode(c.encoding)
    ok(bytes) -> return Answer(passed: true, data: bytes.to_a, text: "", message: "")
    error(e) -> return Answer(passed: false, data: [], text: "", message: e.message)
  end
end

def main() -> Void
  cases = JSON.decode(IO.read(), Cases).unwrap!.cases
  puts(JSON.encode(cases.map do |c: Case| answer(c) end))
end
