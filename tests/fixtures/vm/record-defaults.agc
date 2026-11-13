# The HTTP and TLS option records have defaults from the catalog: a construction may leave those fields out.
import HTTP from "std/http"

def main() -> Void
  c = HTTP.ClientOptions()
  puts("#{c.timeout_ms} #{c.idle_timeout_ms} #{c.max_connections} #{c.max_body_bytes} #{c.tls.none?}")
  given = HTTP.ClientOptions(max_connections: 2, tls: none)
  puts("#{given.timeout_ms} #{given.max_connections} #{given.tls.none?}")
  s = HTTP.ServerOptions(request_timeout_ms: 5)
  puts("#{s.request_timeout_ms} #{s.idle_timeout_ms} #{s.max_connections} #{s.max_body_bytes}")
  puts(HTTP.ServerOptions().inspect)
  puts(TLS.ClientOptions(ca_file: "ca.pem").inspect)
end
