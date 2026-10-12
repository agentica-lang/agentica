def head(dir: String, message: String) -> String
  return String.split(String.split(String.replace(message, dir, "<tls>"), "\n")[0], " (")[0]
end

def main() -> Void
  dir = System.args()[0]
  cert = "#{dir}/server.pem"
  IO.inspect(TLS.connect("localhost", 443, cert, 0))
  IO.inspect(TLS.listen("127.0.0.1", 0, cert, "key#{String.from_code(0)}"))
  puts(head(dir, Result.message(TLS.listen("127.0.0.1", 0, "#{dir}/missing.pem", cert))))
  puts(head(dir, Result.message(TLS.listen("127.0.0.1", 0, cert, "#{dir}/wrong-host-key.pem"))))
  puts(head(dir, Result.message(TLS.connect("localhost", 443, "#{dir}/make-certs.sh", 1000))))
end
