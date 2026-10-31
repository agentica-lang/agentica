# A producer that is busy between sends learns that its reader closed the channel without a failed send: closed? is
# the close flag, true while a value is still buffered, and empty? says that no value is left to receive.

struct Feed
  out: Channel[Int]
  said: Channel[String]
  go: Channel[Bool]
end

def produce(feed: Feed) -> Result[Void]
  try feed.out.send(1, 5000)
  try feed.out.send(2, 5000)
  try feed.said.send("sent two", 5000)
  # The work before the next send (the next token, the next piece of a file); the reader closes meanwhile.
  try feed.go.recv(5000)
  try feed.said.send("producer: closed? #{feed.out.closed?}", 5000)
  return ok()
end

def show(out: Channel[Int]) -> Void
  puts("closed? #{out.closed?}, empty? #{out.empty?}")
end

def main() -> Void
  feed = Feed(out: Channel.new(4), said: Channel.new(1), go: Channel.new(1))
  show(feed.out)
  producer = Task.spawn(&produce, feed)
  puts(feed.said.recv(5000).unwrap!)
  puts(feed.out.recv(5000).unwrap!)
  feed.out.close
  show(feed.out)
  feed.go.send(true, 5000).unwrap!
  puts(feed.said.recv(5000).unwrap!)
  puts(feed.out.recv(0).unwrap!)
  show(feed.out)
  case feed.out.recv(0)
    ok(value) -> puts(value)
    error(message) -> puts("recv: #{message}")
  end
  puts(Task.await(producer).ok?)
end
