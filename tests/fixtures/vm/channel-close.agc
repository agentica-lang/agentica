def show(label: String, r: Result[Void]) -> Void
  case r
    ok(_) -> puts("#{label}: ok")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  ch: Channel[Int] = Channel.new(4)
  ch.send(1, 100)
  ch.send(2, 100)
  ch.send(3, 100)
  puts("closed? #{ch.closed?}, empty? #{ch.empty?}")
  ch.close
  ch.close
  puts("closed? #{ch.closed?}, empty? #{ch.empty?}")
  show("send after close", ch.send(4, 100))
  puts(ch.recv(100).unwrap!)
  puts(ch.recv(100).unwrap!)
  puts("closed? #{ch.closed?}, empty? #{ch.empty?}")
  puts(ch.recv(100).unwrap!)
  puts("closed? #{ch.closed?}, empty? #{ch.empty?}")
  case ch.recv(100)
    ok(n) -> puts(n)
    error(e) -> puts("recv: #{e}")
  end
  show("send again", ch.send(5, 0))
  ch.close
  puts("closed? #{ch.closed?}, empty? #{ch.empty?}")
end
