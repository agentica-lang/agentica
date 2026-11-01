# ALPN between a client and a server of one program: the server picks the first of its protocols that the client
# offers too. TLS.alpn is "" when nothing was selected and on a plain socket.
def offer(port: Int, alpn: List[String], ca: String) -> Result[String]
  tls = try TLS.client_context(TlsClientOptions(ca_file: ca, alpn: alpn))
  socket = try TLS.connect("localhost", port, tls, 5000)
  try TCP.send(socket, "#{TLS.alpn(socket)}\n", 5000)
  return TCP.read_line(socket, 5000)
end

def answer(listener: Listener) -> Result[String]
  socket = try TCP.accept(listener, 5000)
  line = try TCP.read_line(socket, 5000)
  try TCP.send(socket, "#{TLS.alpn(socket)}\n", 5000)
  return ok(line)
end

def serve(dir: String, alpn: List[String]) -> Listener
  options = TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem", alpn: alpn)
  return TLS.listen("127.0.0.1", 0, TLS.server_context(options).unwrap!).unwrap!
end

def talk(listener: Listener, alpn: List[String], ca: String) -> Void
  port = TCP.local_port(listener)
  client = Task.spawn do offer(port, alpn, ca) end
  IO.inspect([answer(listener), Task.await(client)])
end

def main() -> Void
  dir = System.args()[0]
  ca = "#{dir}/ca.pem"
  listener = serve(dir, ["h2", "http/1.1"])
  talk(listener, ["http/1.1", "h2"], ca)
  talk(listener, ["http/1.1"], ca)
  talk(listener, [], ca)
  # No protocol in common: the server refuses the handshake.
  port = TCP.local_port(listener)
  client = Task.spawn do offer(port, ["spdy/3"], ca) end
  IO.inspect(TCP.accept(listener, 5000).ok?)
  IO.inspect(Task.await(client).ok?)
  # A server without ALPN selects nothing.
  talk(serve(dir, []), ["h2"], ca)
  plain = TCP.listen("127.0.0.1", 0).unwrap!
  IO.inspect(TLS.alpn(TCP.connect("127.0.0.1", TCP.local_port(plain), 5000).unwrap!))
  IO.inspect(TLS.client_context(TlsClientOptions(alpn: [""])))
  long = ""
  for n in 0...256
    long = long + "x"
  end
  IO.inspect(TLS.client_context(TlsClientOptions(alpn: [long.slice(0, 255)])).ok?)
  IO.inspect(TLS.client_context(TlsClientOptions(alpn: [long])))
  # The list takes at most 65535 bytes, each name after its length byte: 255 names of 255 bytes and one of 254 fit.
  full = (0...255).to_a.map do |_n: Int| long.slice(0, 255) end
  IO.inspect(TLS.client_context(TlsClientOptions(alpn: full.push(long.slice(0, 254)))).ok?)
  IO.inspect(TLS.client_context(TlsClientOptions(alpn: full.push(long.slice(0, 255)))))
  IO.inspect(
    TLS.server_context(
      TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem", alpn: ["h2", ""]),
    ),
  )
end
