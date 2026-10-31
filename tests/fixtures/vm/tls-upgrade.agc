# STARTTLS inside one program: each side trades plain lines, then TLS.upgrade starts TLS on its socket. The client
# task prints nothing, so the output does not depend on which side finishes its handshake first.
def starttls(port: Int, tls: TlsContext, host: String) -> Result[List[String]]
  plain = try TCP.connect("127.0.0.1", port, 5000)
  try TCP.send(plain, "STARTTLS\n", 5000)
  ready = try TCP.read_line(plain, 5000)
  socket = try TLS.upgrade(plain, tls, host, 5000)
  try TCP.send(socket, "#{ready} hello\n", 5000)
  reply = try TCP.read_line(socket, 5000)
  return ok([TCP.send(plain, "plain\n", 5000).message, reply])
end

def answer(listener: Listener, server: TlsContext) -> Result[String]
  plain = try TCP.accept(listener, 5000)
  puts(try TCP.read_line(plain, 5000))
  try TCP.send(plain, "ready\n", 5000)
  socket = try TLS.upgrade(plain, server, "", 5000)
  IO.inspect(TCP.read_line(plain, 5000))
  line = try TCP.read_line(socket, 5000)
  try TCP.send(socket, "#{line}!\n", 5000)
  IO.inspect(TLS.upgrade(socket, server, "", 5000))
  return ok(line)
end

def main() -> Void
  dir = System.args()[0]
  server = TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem"))
  tls = TLS.client_context(TlsClientOptions(ca_file: "#{dir}/ca.pem")).unwrap!
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  task = Task.spawn do starttls(port, tls, "localhost") end
  IO.inspect(answer(listener, server.unwrap!))
  IO.inspect(Task.await(task))
  # The wrong name: the client's check fails the upgrade, and the server's handshake ends with it.
  wrong = Task.spawn do starttls(port, tls, "example.com") end
  IO.inspect(answer(listener, server.unwrap!).ok?)
  puts(String.split(Task.await(wrong).message, " (")[0])
  # The checks of the arguments leave the socket open; a closed socket stays closed.
  plain = TCP.connect("127.0.0.1", port, 5000).unwrap!
  IO.inspect(TLS.upgrade(plain, tls, "", 5000))
  IO.inspect(TLS.upgrade(plain, tls, "localhost", 0))
  IO.inspect(TCP.send(plain, "still open\n", 5000))
  TCP.close(plain)
  IO.inspect(TLS.upgrade(plain, tls, "localhost", 5000))
end
