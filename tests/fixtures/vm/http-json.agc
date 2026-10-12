def main() -> Void
  puts(JSON.schema(HttpClientOptions))
  h = Header(name: "a", value: "ñ")
  text = JSON.encode(h)
  puts(text)
  IO.inspect(JSON.decode(text, Header))
  puts(JSON.schema(Header))
  r = HttpResponse(status: 200, headers: [h], body: "x")
  IO.inspect(JSON.decode(JSON.encode(r), HttpResponse))
  IO.inspect(JSON.decode("{\"name\": 1}", Header))
end
