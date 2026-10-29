def client(port: Int) -> Result[String]
  socket = TLS.connect("localhost", port, "#{System.args()[0]}/ca.pem", 5000).unwrap!
  TCP.send_bytes(socket, Bytes.from_list([104, 195, 177, 10]).unwrap!, 5000).unwrap!
  return TCP.read_line(socket, 5000)
end

def main() -> Void
  dir = System.args()[0]
  listener = TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem").unwrap!
  task = Task.spawn(&client, TCP.local_port(listener))
  socket = TCP.accept(listener, 5000).unwrap!
  TCP.send(socket, TCP.read_line(socket, 5000).unwrap! + "!\n", 5000).unwrap!
  IO.inspect(Task.await(task))
end
