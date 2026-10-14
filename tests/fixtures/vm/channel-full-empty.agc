def show(label: String, r: Result[Void]) -> Void
  case r
    ok(_) -> puts("#{label}: ok")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  ch: Channel[String] = Channel.new(2)
  case ch.recv(0)
    ok(text) -> puts(text)
    error(e) -> puts("empty recv: #{e}")
  end
  show("send a", ch.send("a", 0))
  show("send b", ch.send("b", 0))
  show("send c", ch.send("c", 0))
  puts(ch.closed?)
  puts(ch.recv(0).unwrap!)
  show("send c again", ch.send("c", 0))
  puts(ch.recv(0).unwrap!)
  puts(ch.recv(0).unwrap!)
  case ch.recv(0)
    ok(text) -> puts(text)
    error(e) -> puts("empty recv: #{e}")
  end
  puts(ch.closed?)
  IO.inspect(ch)
end
