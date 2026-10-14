import "std/http" as HTTP

struct Quote
  item: String
  quantity: Int
end

struct Reply
  item: String
  unit_cents: Int
  total_cents: Int
end

def failure_text(body: String) -> String
  parsed = JSON.parse(body)
  if !parsed.ok?
    return "error: bad response"
  end
  field = JSON.get(parsed.unwrap!, "error")
  if !field.ok?
    return "error: bad response"
  end
  message = JSON.string(field.unwrap!)
  if !message.ok?
    return "error: bad response"
  end
  return "error: #{message.unwrap!}"
end

def quote(client: HttpClient, base: String, item: String, quantity: Int) -> String
  body = JSON.encode(Quote(item: item, quantity: quantity))
  headers = [Header(name: "Content-Type", value: "application/json")]
  sent = HTTP.post(client, base + "/quote", headers, body)
  if !sent.ok?
    return "error: no response"
  end
  response = sent.unwrap!
  if response.status == 200
    reply = JSON.decode(response.body, Reply)
    if !reply.ok?
      return "error: bad response"
    end
    return "#{item}: #{reply.unwrap!.total_cents}"
  elsif response.status == 400 || response.status == 404
    return failure_text(response.body)
  end
  return "error: bad response"
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
