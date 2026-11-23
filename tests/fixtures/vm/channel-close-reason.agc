def failure(text: String) -> Result[Void] = error(text, kind: "net.closed", code: 104)

def close_with(ch: Channel[Int], text: String) -> Void
  case failure(text)
    ok(_) -> ch.close
    error(e) -> ch.close(e)
  end
end

def show(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: #{n}")
    error(e) -> puts("#{label}: #{e.kind} #{e.message} #{e.code}")
  end
end

def show_send(label: String, r: Result[Void]) -> Void
  case r
    ok(_) -> puts("#{label}: ok")
    error(e) -> puts("#{label}: #{e.kind} #{e.message}")
  end
end

def wait_send(ch: Channel[Int]) -> Result[Void] = ch.send(9, 5000)

def wait_recv(ch: Channel[Int]) -> Result[Int] = ch.recv(5000)

def main() -> Void
  ch: Channel[Int] = Channel.new(2)
  _ = ch.send(1, 0)
  _ = ch.send(2, 0)
  sender = Task.spawn(&wait_send, ch)
  Task.sleep(10)
  close_with(ch, "reset by peer")
  close_with(ch, "second")
  ch.close
  show_send("parked sender", Task.await(sender))
  show_send("send", ch.send(3, 0))
  show_send("address send", ch.address.send(3, 0))
  puts("closed? #{ch.closed?}, empty? #{ch.empty?}")
  show("recv", ch.recv(0))
  show("recv", ch.recv(0))
  show("recv", ch.recv(0))
  show("recv again", ch.recv(100))

  waiting: Channel[Int] = Channel.new(1)
  receiver = Task.spawn(&wait_recv, waiting)
  Task.sleep(10)
  close_with(waiting, "producer gave up")
  show("parked receiver", Task.await(receiver))

  plain: Channel[Int] = Channel.new(1)
  plain.close
  close_with(plain, "too late")
  show("plain then reason", plain.recv(0))

  same: Channel[Int] = Channel.new(1)
  case failure("same")
    ok(_) -> same.close
    error(e) ->
      same.close(e)
      case same.recv(0)
        ok(_) -> puts("no error")
        error(got) -> puts("same error: #{got == e}, location kept: #{got.location == e.location}")
      end
  end

  stream: Channel[Int] = Channel.new(4)
  _ = stream.send(10, 0)
  _ = stream.send(20, 0)
  close_with(stream, "cut short")
  done = stream.lazy(100).each do |n|
    puts("each #{n}")
    ok()
  end

  puts(done)
  puts(stream.lazy(100).to_a)
end
