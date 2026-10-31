# The HTTP option records have a default on every field, from the catalog: a construction may leave any out.
def main() -> Void
  c = HttpClientOptions()
  puts("#{c.timeout_ms} #{c.idle_timeout_ms} #{c.max_connections} #{c.max_body_bytes} [#{c.ca_file}]")
  given = HttpClientOptions(max_connections: 2, ca_file: "ca.pem")
  puts("#{given.timeout_ms} #{given.max_connections} #{given.ca_file}")
  s = HttpServerOptions(request_timeout_ms: 5)
  puts("#{s.request_timeout_ms} #{s.idle_timeout_ms} #{s.max_connections} #{s.max_body_bytes}")
  puts(HttpServerOptions().inspect)
end
