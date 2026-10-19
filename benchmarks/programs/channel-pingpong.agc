struct Pair
  ping: Channel[Int]
  pong: Channel[Int]
  rounds: Int
end

def scale() -> Int
  return 1
end

def echo(p: Pair) -> Int
  n = 0
  while n < p.rounds
    case p.ping.recv(5000)
      ok(v) ->
        _ = p.pong.send(v + 1, 5000)
        n += 1
      error(_) -> return -1
    end
  end
  return n
end

def main() -> Void
  rounds = 100000 * scale()
  p = Pair(ping: Channel.new(1), pong: Channel.new(1), rounds: rounds)
  worker = Task.spawn(&echo, p)
  total = 0
  i = 0
  while i < rounds
    _ = p.ping.send(i, 5000)
    case p.pong.recv(5000)
      ok(v) -> total += v
      error(_) -> return
    end
    i += 1
  end
  puts("channel-pingpong #{rounds}: checksum #{total} #{Task.await(worker)}")
end
