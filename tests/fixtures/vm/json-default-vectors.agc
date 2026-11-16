# Checks typed JSON with field defaults against the vectors of tests/fixtures/json-default-vectors.py: each document
# is decoded from its text and from its JSON.Value value, and both must give the peer's encoded text or error message.
# A "same" vector must come back unchanged up to key order, and every decoded value must encode back to the same text
# after a second decode (the round trip).
struct Item
  sku: String
  qty: Int = 1
  price: Float = 0.5
end

struct Order
  id: Int
  note: String = ""
  rush: Bool = false
  ratio: Float = -2.5
  count: Int = -7
  tags: List[String] = []
  limits: Map[String, Int] = {}
  items: List[Item] = []
  main: Item
end

# The outcome of one decode in the peer's words: "ok", a tab and the encoded text, or "error", a tab and the message.
def outcome(decoded: Result[Order]) -> String
  case decoded
    ok(patch) -> "ok\t#{JSON.encode(patch)}"
    error(message) -> "error\t#{message}"
  end
end

# The document with its object keys sorted, so two documents compare up to key order.
def sorted(text: String) -> String = JSON.encode(JSON.parse(text).unwrap!)

def check(line: String) -> Int
  fields = line.split("\t")
  want = "#{fields[1]}\t#{fields[2]}"
  from_text = outcome(JSON.decode(fields[0], Order))
  from_value = outcome(JSON.decode(JSON.parse(fields[0]).unwrap!, Order))
  if from_text != want or from_value != want
    puts("#{fields[0]}: text gave #{from_text}, Json gave #{from_value}, want #{want}")
    return 1
  end

  if fields[1] == "ok" and outcome(JSON.decode(fields[2], Order)) != want
    puts("#{fields[0]}: the encoded text does not decode to itself")
    return 1
  end

  same = fields[1] == "ok" && sorted(fields[2]) == sorted(fields[0])
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
