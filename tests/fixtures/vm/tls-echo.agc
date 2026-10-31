def client(port: Int, tls: TlsContext) -> Result[String]
  socket = TLS.connect("localhost", port, tls, 5000).unwrap!
  TCP.send_bytes(socket, Bytes.from_list([104, 195, 177, 10]).unwrap!, 5000).unwrap!
  return TCP.read_line(socket, 5000)
end

def main() -> Void
  dir = System.args()[0]
  server = TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem"))
  listener = TLS.listen("127.0.0.1", 0, server.unwrap!).unwrap!
  tls = TLS.client_context(TlsClientOptions(ca_file: "#{dir}/ca.pem")).unwrap!
  IO.inspect(tls)
  port = TCP.local_port(listener)
  task = Task.spawn do client(port, tls) end
  socket = TCP.accept(listener, 5000).unwrap!
  TCP.send(socket, TCP.read_line(socket, 5000).unwrap! + "!\n", 5000).unwrap!
  IO.inspect(Task.await(task))
end
