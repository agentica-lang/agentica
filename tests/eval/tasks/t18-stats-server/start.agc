import HTTP from "std/http"

struct Stats
  count: Int
  total: Int
  min: Int
  max: Int
end

def text_response(status: Int, body: String) -> HttpResponse
  return HttpResponse(status: status, headers: [Header(name: "Content-Type", value: "text/plain")], body: body.bytes)
end

def stats_response(body: String) -> HttpResponse
  root = JSON.parse(body).unwrap!
  items = JSON.list(JSON.get(root, "values").unwrap!).unwrap!
  numbers: List[Int] = []
  for item in items
    numbers = numbers.push(JSON.int(item).unwrap!)
  end
  sorted = numbers.sort
  total = numbers.reduce(0) do |sum, n| sum + n end
  stats = Stats(count: numbers.size, total: total, min: sorted[sorted.size - 1], max: sorted[0])
  return text_response(200, JSON.encode(stats))
end

def handle(request: HttpRequest) -> Result[HttpResponse]
  path = request.path
  if path == "/health" && request.method == "GET"
    return ok(text_response(200, JSON.encode({"status": "ok"})))
  elsif path == "/stats" && request.method == "POST"
    return ok(stats_response(HTTP.text(request.body, request.headers).unwrap!))
  elsif path == "/hello" && request.method == "GET"
    return ok(text_response(200, JSON.encode({"greeting": "hello, world"})))
  elsif path.starts_with?("/double/") && request.method == "GET"
    n = path.slice(8, path.length - 8).to_i!
    return ok(text_response(200, JSON.encode({"n": n, "double": n * 2})))
  end
  return ok(text_response(200, JSON.encode({"error": "not found"})))
end

def main() -> Void
  port = 0
  server = HTTP.listen("127.0.0.1", port, &handle).unwrap!
  puts("listening #{port}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
