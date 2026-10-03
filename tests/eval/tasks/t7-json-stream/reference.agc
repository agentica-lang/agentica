struct Reply
  id: Int
  result: Int
end

def handle_request(text: String) -> Result[Reply]
  root = try JSON.parse(text)
  id = try JSON.int(try JSON.get(root, "id"))
  op = try JSON.string(try JSON.get(root, "op"))
  values = try JSON.list(try JSON.get(root, "values"))
  if op == "count"
    return ok(Reply(id: id, result: List.size(values)))
  elsif op == "sum"
    total = 0
    for value in values
      total = total + (try JSON.int(value))
    end
    return ok(Reply(id: id, result: total))
  else
    return error("invalid request")
  end
end

def main() -> Nil
  while not IO.eof?()
    reply = handle_request(IO.gets!())
    if Result.ok?(reply)
      puts(JSON.encode(Result.unwrap!(reply)))
    else
      puts(JSON.encode({"error": "invalid request"}))
    end
    IO.flush()
  end
end
