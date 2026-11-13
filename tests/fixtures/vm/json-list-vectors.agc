# Checks JSON.decode of List and Map targets against the vectors of tests/fixtures/json-list-vectors.py: each document
# is decoded from its text and from its JSON.Value value into the target the vector names, and both must give the peer's
# encoded text or error message. A "same" vector must come back unchanged up to key order, and the encoded text must
# decode to itself (the round trip). No struct field is an Optional: the Optional enum is in the table only for the
# List[Optional[Int]] target.
struct Item
  name: String
  count: Int
end

enum Color
  Red
  Blue
end

# The outcome of one decode in the peer's words: "ok", a tab and the encoded text, or "error", a tab and the message.
def outcome[T](decoded: Result[T]) -> String
  case decoded
    ok(value) -> return "ok\t#{JSON.encode(value)}"
    error(message) -> return "error\t#{message}"
  end
end

# The outcomes of the decode of text into the target, from the text and from its JSON.Value value.
def outcomes(target: String, text: String) -> List[String]
  value = JSON.parse(text).unwrap!
  if target == "list"
    return [outcome(JSON.decode(text, List[Item])), outcome(JSON.decode(value, List[Item]))]
  elsif target == "map"
    return [outcome(JSON.decode(text, Map[String, Item])), outcome(JSON.decode(value, Map[String, Item]))]
  elsif target == "ints"
    return [outcome(JSON.decode(text, List[Int])), outcome(JSON.decode(value, List[Int]))]
  elsif target == "optionals"
    return [outcome(JSON.decode(text, List[Optional[Int]])), outcome(JSON.decode(value, List[Optional[Int]]))]
  elsif target == "colors"
    return [outcome(JSON.decode(text, List[Color])), outcome(JSON.decode(value, List[Color]))]
  elsif target == "grid"
    return [outcome(JSON.decode(text, List[List[Item]])), outcome(JSON.decode(value, List[List[Item]]))]
  end

  return [outcome(JSON.decode(text, Map[String, List[Item]])), outcome(JSON.decode(value, Map[String, List[Item]]))]
end

# The document with its object keys sorted, so two documents compare up to key order.
def sorted(text: String) -> String
  return JSON.encode(JSON.parse(text).unwrap!)
end

def check(line: String) -> Int
  fields = line.split("\t")
  want = "#{fields[2]}\t#{fields[3]}"
  found = outcomes(fields[0], fields[1])
  if found[0] != want or found[1] != want
    puts("#{fields[0]} #{fields[1]}: text gave #{found[0]}, Json gave #{found[1]}, want #{want}")
    return 1
  end

  if fields[2] == "ok" and outcomes(fields[0], fields[3])[0] != want
    puts("#{fields[0]} #{fields[1]}: the encoded text does not decode to itself")
    return 1
  end

  same = fields[2] == "ok" && sorted(fields[3]) == sorted(fields[1])
  if fields[4] != "-" && same != (fields[4] == "same")
    puts("#{fields[0]} #{fields[1]}: round trip #{same}, want #{fields[4]}")
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
