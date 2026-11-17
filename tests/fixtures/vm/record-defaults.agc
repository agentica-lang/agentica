# The HTTP and TLS option records have defaults from the catalog: a construction may leave those fields out.
import HTTP from "std/http"

def main() -> Void
  c = HTTP.ClientOptions()
  puts("#{c.timeout_ms} #{c.idle_timeout_ms} #{c.max_connections} #{c.max_body_bytes} #{c.tls.none?}")
  puts("#{c.connect_timeout_ms} #{c.read_timeout_ms} #{c.with(read_timeout_ms: 0).read_timeout_ms}")
  puts("#{c.connect_to.empty?} #{c.with(connect_to: "127.0.0.1").connect_to}")
  given = HTTP.ClientOptions(max_connections: 2, tls: none)
  puts("#{given.timeout_ms} #{given.max_connections} #{given.tls.none?}")
  s = HTTP.ServerOptions(request_timeout_ms: 5)
  puts("#{s.request_timeout_ms} #{s.idle_timeout_ms} #{s.max_connections} #{s.max_body_bytes}")
  puts(HTTP.ServerOptions().inspect)
  puts(TLS.ClientOptions(ca_file: "ca.pem").inspect)
end
