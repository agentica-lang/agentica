struct Pair
  a: Channel[Int]
  b: Channel[Int]
  rounds: Int
end

def scale() -> Int
  return 1
end

def echo(p: Pair) -> Int
  total = 0
  n = 0
  while n < p.rounds
    case p.a.recv(1000)
      ok(v) ->
        _ = p.b.send(v + 1, 1000)
        total += v
        n += 1
      error(_) ->
        return -1
    end
  end
  return total
end

def main() -> Void
  rounds = 50000 * scale()
  p = Pair(a: Channel.new(1), b: Channel.new(1), rounds: rounds)
  worker = Task.spawn(&echo, p)
  total = 0
  i = 0
  while i < rounds
    _ = p.a.send(i, 1000)
    case p.b.recv(1000)
      ok(v) -> total += v
      error(_) -> return
    end
    i += 1
  end
  puts("deadline-pingpong #{rounds}: checksum #{total} #{Task.await(worker)}")
end
