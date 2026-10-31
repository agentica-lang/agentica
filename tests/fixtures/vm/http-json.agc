struct Reply
  code: Int
  headers: List[Header]
end

def main() -> Void
  puts(JSON.schema(HttpServerOptions))
  h = Header(name: "a", value: "ñ")
  text = JSON.encode(h)
  puts(text)
  IO.inspect(JSON.decode(text, Header))
  puts(JSON.schema(Header))
  IO.inspect(JSON.decode("{\"name\": 1}", Header))
  IO.inspect(JSON.decode("{\"code\": 1, \"headers\": [{\"name\": \"a\", \"value\": \"b\"}]}", Reply))
end
