# TCP.recv_bytes without a timeout waits with no limit: for bytes that come late, behind another reader's lock, after
# a cancel, and until the peer closes. Timeouts above 2^31 ms and the largest Int are taken as given; 0 and negative
# ones are errors.
def wait_bytes(socket: Socket) -> Result[Bytes]
  return TCP.recv_bytes(socket, 16)
end

def wait_byte(socket: Socket) -> Result[Bytes]
  return TCP.recv_bytes(socket, 1)
end

def text(result: Result[Bytes]) -> String = result.unwrap!.decode("UTF-8").unwrap!

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 5000).unwrap!
  server = TCP.accept(listener, 5000).unwrap!
  IO.inspect(TCP.recv_bytes(server, 1, 0))
  IO.inspect(TCP.recv_bytes(server, 1, -1))
  IO.inspect(TCP.recv_bytes(server, 0))
  late = Task.spawn(&wait_bytes, server)
  Task.sleep(200)
  TCP.send_bytes(client, "late".bytes, 1000).unwrap!
  puts(text(Task.await(late)))
  long = Task.spawn do
    TCP.recv_bytes(server, 16, 2147483649)
  end
  Task.sleep(50)
  TCP.send_bytes(client, "2^31 + 1".bytes, 1000).unwrap!
  puts(text(Task.await(long)))
  longest = Task.spawn do
    TCP.recv_bytes(server, 16, 9223372036854775807)
  end
  Task.sleep(50)
  TCP.send_bytes(client, "max Int".bytes, 1000).unwrap!
  puts(text(Task.await(longest)))
  first = Task.spawn(&wait_byte, server)
  second = Task.spawn(&wait_byte, server)
  Task.sleep(50)
  TCP.send_bytes(client, "ab".bytes, 1000).unwrap!
  IO.inspect([text(Task.await(first)), text(Task.await(second))].sort)
  cancelled = Task.spawn(&wait_bytes, server)
  Task.sleep(50)
  Task.cancel(cancelled)
  TCP.send_bytes(client, "kept".bytes, 1000).unwrap!
  puts(text(TCP.recv_bytes(server, 16)))
  closing = Task.spawn(&wait_bytes, server)
  Task.sleep(50)
  TCP.close(client)
  IO.inspect(Task.await(closing))
  TCP.close(server)
  TCP.close_listener(listener)
end
