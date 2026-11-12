# Checks typed JSON for enums against the vectors of tests/fixtures/json-enum-vectors.py: each document is decoded from
# its text and from its JSON.Value value, and both must give the peer's encoded text or error message. A "same" vector must
# come back unchanged up to key order, and every decoded value must encode back to the same text after a second
# decode (the round trip).
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Label(String, Optional[Int])
  Group(List[Shape])
  Empty
end

struct Page
  title: String
  main: Shape
  shapes: List[Shape]
  spare: Optional[Shape]
end

# The outcome of one decode in the peer's words: "ok", a tab and the encoded text, or "error", a tab and the message.
def outcome(decoded: Result[Page]) -> String
  case decoded
    ok(page) -> return "ok\t#{JSON.encode(page)}"
    error(message) -> return "error\t#{message}"
  end
end

# The document with its object keys sorted, so two documents compare up to key order.
def sorted(text: String) -> String
  return JSON.encode(JSON.parse(text).unwrap!)
end

def check(line: String) -> Int
  fields = line.split("\t")
  want = "#{fields[1]}\t#{fields[2]}"
  from_text = outcome(JSON.decode(fields[0], Page))
  from_value = outcome(JSON.decode(JSON.parse(fields[0]).unwrap!, Page))
  if from_text != want or from_value != want
    puts("#{fields[0]}: text gave #{from_text}, Json gave #{from_value}, want #{want}")
    return 1
  end

  if fields[1] == "ok" and outcome(JSON.decode(fields[2], Page)) != want
    puts("#{fields[0]}: the encoded text does not decode to itself")
    return 1
  end

  same = fields[1] == "ok" && sorted(fields[2]) == sorted(fields[0])
  if fields[3] != "-" && same != (fields[3] == "same")
    puts("#{fields[0]}: round trip #{same}, want #{fields[3]}")
    return 1
  end

  return 0
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
      error(_) ->
        running = false
    end
  end

  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
