def head(dir: String, message: String) -> String
  return String.split(String.split(String.replace(message, dir, "<tls>"), "\n")[0], " (")[0]
end

def client(options: TlsClientOptions) -> Result[TlsContext]
  return TLS.client_context(options)
end

def server(cert: String, key: String) -> Result[TlsContext]
  return TLS.server_context(TlsServerOptions(cert_file: cert, key_file: key))
end

def main() -> Void
  dir = System.args()[0]
  cert = "#{dir}/server.pem"
  system = client(TlsClientOptions()).unwrap!
  IO.inspect(TLS.connect("localhost", 443, system, 0))
  IO.inspect(server(cert, "key#{String.from_code(0)}"))
  IO.inspect(server(cert, ""))
  puts(head(dir, server("#{dir}/missing.pem", cert).message))
  puts(head(dir, server(cert, "#{dir}/wrong-host-key.pem").message))
  puts(head(dir, client(TlsClientOptions(ca_file: "#{dir}/make-certs.sh")).message))
  ca = "#{dir}/ca.pem"
  certificate = "#{dir}/client.pem"
  key = "#{dir}/client-key.pem"
  IO.inspect(client(TlsClientOptions(ca_file: ca, cert_file: certificate)))
  IO.inspect(client(TlsClientOptions(ca_file: ca, key_file: key)))
  puts(head(dir, client(TlsClientOptions(ca_file: ca, cert_file: "#{dir}/missing.pem", key_file: key)).message))
  puts(head(dir, client(TlsClientOptions(ca_file: ca, cert_file: certificate, key_file: "#{dir}/missing.pem")).message))
  bad_key = "#{dir}/server-key.pem"
  puts(head(dir, client(TlsClientOptions(ca_file: ca, cert_file: certificate, key_file: bad_key)).message))
end
