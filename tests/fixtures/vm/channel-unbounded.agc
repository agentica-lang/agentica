def show(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: #{n}")
    error(e) -> puts("#{label}: #{e.kind} #{e.message}")
  end
end

def flood(ch: Channel[Int]) -> Int
  sent = 0
  for n in 1..5000
    if ch.send(n, 0).ok?
      sent += 1
    end
  end
  sent
end

def main() -> Void
  ch: Channel[Int] = Channel.new
  puts("sent without a receiver: #{Task.await(Task.spawn(&flood, ch))}")
  sum = 0
  for n in 1..5000
    got = Result.unwrap!(ch.recv(0))
    if got != n
      puts("out of order at #{n}: #{got}")
    end
    sum += got
  end
  puts("sum #{sum}, empty? #{ch.empty?}")
  show("recv on empty", ch.recv(0))

  mailbox: Channel[String] = Channel.new()
  address = mailbox.address
  _ = address.send("hello", 0)
  _ = mailbox.send("world", 0)
  mailbox.close
  puts(Result.unwrap!(mailbox.recv(0)) + " " + Result.unwrap!(mailbox.recv(0)))
  case mailbox.send("late", 0)
    ok(_) -> puts("late: ok")
    error(e) -> puts("late: #{e.message}")
  end

  bounded: Channel[Int] = Channel.new(2)
  _ = bounded.send(1, 0)
  _ = bounded.send(2, 0)
  case bounded.send(3, 0)
    ok(_) -> puts("bounded third: ok")
    error(e) -> puts("bounded third: #{e.message}")
  end
end
