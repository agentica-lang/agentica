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
  for n in 0...p.rounds
    case p.a.recv(1000)
      ok(v) ->
        _ = p.b.send(v + 1, 1000)
        total += v
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
  for i in 0...rounds
    _ = p.a.send(i, 1000)
    case p.b.recv(1000)
      ok(v) -> total += v
      error(_) -> return
    end
  end
  puts("deadline-pingpong #{rounds}: checksum #{total} #{Task.await(worker)}")
end
