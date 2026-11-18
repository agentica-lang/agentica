struct Req
  value: Int
  reply: Channel[Int]
end

def scale() -> Int
  return 1
end

# One busy task that serves every client in turn (#1362): the clients wait for it, so an idle scheduler should take
# the next request without a sleep or a futex wake.
def store(inbox: Channel[Req], total: Int) -> Int
  sum = 0
  n = 0
  while n < total
    case inbox.recv(60000)
      ok(r) ->
        for k in 0...60
          sum += k % 3
        end
        sum += r.value
        _ = r.reply.send(sum, 60000)
        n += 1
      error(_) -> return -1
    end
  end
  sum
end

def client(inbox: Channel[Req], count: Int) -> Int
  reply: Channel[Int] = Channel.new(1)
  answered = 0
  for i in 0...count
    _ = inbox.send(Req(value: i, reply: reply), 60000)
    case reply.recv(60000)
      ok(_) -> answered += 1
      error(_) -> return -1
    end
  end
  answered
end

def main() -> Void
  clients = 50
  per = 1000 * scale()
  inbox: Channel[Req] = Channel.new(64)
  server = Task.spawn do store(inbox, clients * per) end
  tasks: List[Task[Int]] = []
  for _ in 0...clients
    tasks = tasks.push(Task.spawn do client(inbox, per) end)
  end
  total = 0
  for t in tasks
    total += Task.await(t)
  end
  puts("store-clients #{clients * per}: #{Task.await(server)} #{total}")
end
