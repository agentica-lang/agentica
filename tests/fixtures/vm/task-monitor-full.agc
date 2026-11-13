# A notice that finds its channel full goes in past the capacity, so an open channel never loses one: here two notices
# into a channel of one slot that is already taken. A send still finds the channel full until the receiver has taken
# the values over the capacity. The crash counts as observed, so the run exits 0.
def divide(n: Int) -> Int
  return 10 / n
end

def main() -> Void
  inbox: Channel[String] = Channel.new(1)
  _ = inbox.send("busy", 0)
  done = Task.spawn(&divide, 2)
  crashed = Task.spawn(&divide, 0)
  Task.monitor(done, inbox) do |down| "down #{down.reason}" end
  Task.monitor(crashed, inbox) do |down| "down #{down.reason}" end
  Task.sleep(50)
  puts(inbox.send("refused", 0))
  puts(inbox.recv(0))
  downs = [inbox.recv(5000).unwrap!, inbox.recv(5000).unwrap!]
  puts(downs.sort)
  puts(inbox.send("room", 0))
  puts(inbox.recv(0))
  puts(Task.await(done))
end
