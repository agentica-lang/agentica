import HTTP from "std/http"

struct Order
  name: String
  qty: Int
end

struct Priced
  item: String
  price: Int
  total: Int
end

def quote(client: HttpClient, base: String, item: String, quantity: Int) -> String
  body = JSON.encode(Order(name: item, qty: quantity))
  headers = [Header(name: "Content-Type", value: "text/plain")]
  response = HTTP.post(client, base + "/quotes", headers, body).unwrap!
  reply = JSON.decode(response.body, Priced)
  if !reply.ok?
    return "error: bad response"
  end
  return "#{item}: #{reply.unwrap!.total}"
end

def main() -> Void
  base = System.args()[0]
  client = HTTP.client(HTTP.client_options()).unwrap!
  sent = 0
  failed = 0
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    parts = line.split(" ")
    quantity = Result.unwrap_or(parts[parts.size - 1].to_i, 0)
    if parts.size != 2 || quantity < 1
      puts("error: bad order: #{line}")
      next
    end
    text = quote(client, base, parts[0], quantity)
    sent += 1
    if text.starts_with?("error:")
      failed += 1
      puts("#{parts[0]}: #{text}")
    else
      puts(text)
    end
  end
  HTTP.close_client(client)
  puts("orders: #{sent}, failed: #{failed}")
end
