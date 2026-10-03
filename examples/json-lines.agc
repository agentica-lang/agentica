struct ScoreResult
  name: String
  passed: Bool
end

def classify_record(text: String) -> Result[ScoreResult]
  root = try JSON.parse(text)
  name = try JSON.string(try JSON.get(root, "name"))
  score = try JSON.int(try JSON.get(root, "score"))
  active = try JSON.bool(try JSON.get(root, "active"))
  if score < 0 or score > 100
    return error("invalid record")
  end
  return ok(ScoreResult(name: name, passed: active and score >= 60))
end

def main() -> Nil
  while not IO.eof?()
    record = classify_record(IO.gets!())
    if Result.ok?(record)
      puts(JSON.encode(Result.unwrap!(record)))
    else
      puts(JSON.encode({"error": "invalid record"}))
    end
    IO.flush()
  end
end
