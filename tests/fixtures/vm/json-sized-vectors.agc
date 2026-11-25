# Checks typed JSON with the narrow integer types against the vectors of tests/fixtures/json-sized-vectors.py: each
# document is decoded from its text and from its JSON.Value value, and both must give the peer's encoded text or error
# message, with the same round trip checks as json-optional-vectors.agc.
struct Sample
  int8: Int8
  int16: Int16
  int32: Int32
  uint8: UInt8
  uint16: UInt16
  uint32: UInt32
  uint64: UInt64
  byte: Optional[UInt8]
  big: Optional[UInt64]
  shorts: List[Int16]
  counts: Map[String, UInt32]
end

# The outcome of one decode in the peer's words: "ok", a tab and the encoded text, or "error", a tab and the message.
def outcome(decoded: Result[Sample]) -> String
  case decoded
    ok(sample) -> "ok\t#{JSON.encode(sample)}"
    error(message) -> "error\t#{message}"
  end
end

# Whether two documents are the same JSON value: keys in any order, numbers by value.
def same_json?(a: String, b: String) -> Bool = JSON.parse(a).unwrap! == JSON.parse(b).unwrap!

def check(line: String) -> Int
  fields = line.split("\t")
  want = "#{fields[1]}\t#{fields[2]}"
  from_text = outcome(JSON.decode(fields[0], Sample))
  from_value = outcome(JSON.decode(JSON.parse(fields[0]).unwrap!, Sample))
  if from_text != want or from_value != want
    puts("#{fields[0]}: text gave #{from_text}, Json gave #{from_value}, want #{want}")
    return 1
  end

  if fields[1] == "ok" and outcome(JSON.decode(fields[2], Sample)) != want
    puts("#{fields[0]}: the encoded text does not decode to itself")
    return 1
  end

  same = fields[1] == "ok" && same_json?(fields[2], fields[0])
  if fields[3] != "-" && same != (fields[3] == "same")
    puts("#{fields[0]}: round trip #{same}, want #{fields[3]}")
    return 1
  end

  0
end

def main() -> Void
  _ = IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
        count += 1
      error(_) -> running = false
    end
  end

  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
