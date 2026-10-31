def head(dir: String, message: String) -> String
  return String.split(String.split(String.replace(message, dir, "<tls>"), "\n")[0], " (")[0]
end

def client_of(options: TlsClientOptions) -> Result[TlsContext]
  return TLS.client_context(options)
end

def server_of(cert: String, key: String) -> Result[TlsContext]
  return TLS.server_context(TlsServerOptions(cert_file: cert, key_file: key))
end

def main() -> Void
  dir = System.args()[0]
  cert = "#{dir}/server.pem"
  IO.inspect(TLS.connect("localhost", 443, cert, 0))
  IO.inspect(TLS.listen("127.0.0.1", 0, cert, "key#{String.from_code(0)}"))
  puts(head(dir, Result.message(TLS.listen("127.0.0.1", 0, "#{dir}/missing.pem", cert))))
  puts(head(dir, Result.message(TLS.listen("127.0.0.1", 0, cert, "#{dir}/wrong-host-key.pem"))))
  puts(head(dir, Result.message(TLS.connect("localhost", 443, "#{dir}/make-certs.sh", 1000))))
  ca = "#{dir}/ca.pem"
  client = "#{dir}/client.pem"
  key = "#{dir}/client-key.pem"
  IO.inspect(TLS.connect("localhost", 443, ca, 1000, client))
  IO.inspect(TLS.connect("localhost", 443, ca, 1000, "", key))
  puts(head(dir, Result.message(TLS.connect("localhost", 443, ca, 1000, "#{dir}/missing.pem", key))))
  puts(head(dir, Result.message(TLS.connect("localhost", 443, ca, 1000, client, "#{dir}/missing.pem"))))
  puts(head(dir, Result.message(TLS.connect("localhost", 443, ca, 1000, client, "#{dir}/server-key.pem"))))
  # The same checks when a context is built.
  IO.inspect(server_of(cert, "key#{String.from_code(0)}"))
  IO.inspect(server_of(cert, ""))
  puts(head(dir, server_of("#{dir}/missing.pem", cert).message))
  puts(head(dir, server_of(cert, "#{dir}/wrong-host-key.pem").message))
  puts(head(dir, client_of(TlsClientOptions(ca_file: "#{dir}/make-certs.sh")).message))
  IO.inspect(client_of(TlsClientOptions(ca_file: ca, cert_file: client)))
  puts(
    head(dir, client_of(TlsClientOptions(ca_file: ca, cert_file: client, key_file: "#{dir}/server-key.pem")).message),
  )
  IO.inspect(TLS.listen("127.0.0.1", 0, server_of(cert, "#{dir}/server-key.pem").unwrap!).ok?)
end
