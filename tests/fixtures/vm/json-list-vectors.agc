# Checks JSON.decode of a List[T] and a Map[String, T] against the vectors of tests/fixtures/json-list-vectors.py:
# each document is decoded from its text and from its Json value into the target the vector names, and both must give
# the peer's encoded text or error message. A "same" vector must come back unchanged up to key order, and the encoded
# text must decode to itself (the round trip).
struct Item
  name: String
  count: Optional[Int]
end

# The outcome of one decode in the peer's words: "ok", a tab and the encoded text, or "error", a tab and the message.
def outcome_list(decoded: Result[List[Item]]) -> String
  case decoded
    ok(items) -> return "ok\t#{JSON.encode(items)}"
    error(message) -> return "error\t#{message}"
  end
end

def outcome_map(decoded: Result[Map[String, Item]]) -> String
  case decoded
    ok(items) -> return "ok\t#{JSON.encode(items)}"
    error(message) -> return "error\t#{message}"
  end
end

# The outcomes of the decode of text into the target, from the text and from its Json value.
def outcomes(target: String, text: String) -> List[String]
  value = JSON.parse(text).unwrap!
  if target == "list"
    return [outcome_list(JSON.decode(text, List[Item])), outcome_list(JSON.decode(value, List[Item]))]
  end

  return [outcome_map(JSON.decode(text, Map[String, Item])), outcome_map(JSON.decode(value, Map[String, Item]))]
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
    puts("#{fields[1]}: text gave #{found[0]}, Json gave #{found[1]}, want #{want}")
    return 1
  end

  if fields[2] == "ok" and outcomes(fields[0], fields[3])[0] != want
    puts("#{fields[1]}: the encoded text does not decode to itself")
    return 1
  end

  same = fields[2] == "ok" && sorted(fields[3]) == sorted(fields[1])
  if fields[4] != "-" && same != (fields[4] == "same")
    puts("#{fields[1]}: round trip #{same}, want #{fields[4]}")
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
