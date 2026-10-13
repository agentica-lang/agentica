import "std/http" as HTTP

def options(timeout_ms: Int, max_connections: Int) -> HttpClientOptions
  return HttpClientOptions(timeout_ms: timeout_ms, idle_timeout_ms: 30000, max_connections: max_connections,
                           max_body_bytes: 1048576, ca_file: "")
end

def main() -> Void
  Test.run([
    Test.test("default client options") do
      Test.eq(HTTP.client_options(), options(30000, 4))
    end,
    Test.test("client options are checked") do
      try Test.eq(HTTP.client(options(0, 4)).message, "http: every option must be positive")
      Test.eq(HTTP.client(options(1000, 65537)).message, "http: max_connections must be at most 65536")
    end,
    Test.test("header values match names in any case") do
      headers = [Header(name: "Set-Cookie", value: "a=1"), Header(name: "Content-Type", value: "text/plain"),
                 Header(name: "set-cookie", value: "b=2")]
      try Test.eq(HTTP.header_values(headers, "SET-COOKIE"), ["a=1", "b=2"])
      Test.eq(HTTP.header_values(headers, "x-missing"), [])
    end,
    Test.test("bad URLs fail before any connection") do
      pool = try HTTP.client(HTTP.client_options())
      scheme = HTTP.get(pool, "ftp://example.com/")
      port = HTTP.get(pool, "http://example.com:0/")
      HTTP.close_client(pool)
      try Test.eq(scheme.message, "http: the URL must be http:// or https:// with a host, and without user info")
      Test.eq(port.message, "http: the port must be 1..65535")
    end
  ])
end
