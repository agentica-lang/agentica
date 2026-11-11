import HTTP from "std/http"

struct Reply
  code: Int
  headers: List[HTTP.Header]
end

def main() -> Void
  puts(JSON.schema(HTTP.ServerOptions))
  h = HTTP.Header(name: "a", value: "ñ")
  text = JSON.encode(h)
  puts(text)
  IO.inspect(JSON.decode(text, HTTP.Header))
  puts(JSON.schema(HTTP.Header))
  IO.inspect(JSON.decode("{\"name\": 1}", HTTP.Header))
  IO.inspect(JSON.decode("{\"code\": 1, \"headers\": [{\"name\": \"a\", \"value\": \"b\"}]}", Reply))
end
