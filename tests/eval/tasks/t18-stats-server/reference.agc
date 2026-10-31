import HTTP from "std/http"

struct Stats
  count: Int
  sum: Int
  min: Int
  max: Int
end

def json_response(status: Int, body: String) -> HttpResponse
  return HttpResponse(status: status, headers: [Header(name: "Content-Type", value: "application/json")], body: body.bytes)
end

def failure(status: Int, message: String) -> HttpResponse
  return json_response(status, JSON.encode({"error": message}))
end

def not_allowed(allow: String) -> HttpResponse
  headers = [Header(name: "Content-Type", value: "application/json"), Header(name: "Allow", value: allow)]
  return HttpResponse(status: 405, headers: headers, body: JSON.encode({"error": "method not allowed"}).bytes)
end

def integers(root: Json) -> Result[List[Int]]
  field = try JSON.get(root, "values")
  items = try JSON.list(field)
  if items.size == 0
    return error("empty")
  end
  numbers: List[Int] = []
  for item in items
    numbers = numbers.push(try JSON.int(item))
  end
  return ok(numbers)
end

def stats_response(body: String) -> HttpResponse
  root = JSON.parse(body)
  if !root.ok?
    return failure(400, "invalid json")
  end
  numbers = integers(root.unwrap!)
  if !numbers.ok?
    return failure(400, "values must be a non-empty array of integers")
  end
  values = numbers.unwrap!
  sorted = values.sort
  total = values.reduce(0) do |sum, n| sum + n end
  stats = Stats(count: values.size, sum: total, min: sorted[0], max: sorted[sorted.size - 1])
  return json_response(200, JSON.encode(stats))
end

def is_integer(text: String) -> Bool
  digits = text
  if text.starts_with?("-")
    digits = text.slice(1, text.length - 1)
  end
  if digits == ""
    return false
  end
  for i in 0...digits.length
    code = String.code(digits.at(i))
    if code < 48 || code > 57
      return false
    end
  end
  return true
end

def query_name(query: String) -> String
  for pair in query.split("&")
    if pair.starts_with?("name=") && pair.length > 5
      return pair.slice(5, pair.length - 5)
    end
  end
  return "world"
end

def greeting(target: String) -> String
  case target.index_of("?")
    some(index) -> return greeting_for(query_name(target.slice(index + 1, target.length - index - 1)))
    none -> return greeting_for("world")
  end
end

def greeting_for(name: String) -> String
  return JSON.encode({"greeting": "hello, #{name}"})
end

def handle(request: HttpRequest) -> Result[HttpResponse]
  path = request.path
  if path == "/health"
    if request.method != "GET"
      return ok(not_allowed("GET"))
    end
    return ok(json_response(200, JSON.encode({"status": "ok"})))
  elsif path == "/stats"
    if request.method != "POST"
      return ok(not_allowed("POST"))
    end
    case HTTP.text(request.body, request.headers)
      ok(body) -> return ok(stats_response(body))
      error(_) -> return ok(failure(400, "invalid json"))
    end
  elsif path == "/hello"
    if request.method != "GET"
      return ok(not_allowed("GET"))
    end
    return ok(json_response(200, greeting(request.target)))
  elsif path.starts_with?("/double/")
    if request.method != "GET"
      return ok(not_allowed("GET"))
    end
    text = path.slice(8, path.length - 8)
    if !is_integer(text)
      return ok(failure(400, "not an integer"))
    end
    n = text.to_i!
    return ok(json_response(200, JSON.encode({"n": n, "double": n * 2})))
  end
  return ok(failure(404, "not found"))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  puts("listening #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
