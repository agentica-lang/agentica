struct Box
  inbox: Channel[Int]
end

def take(inbox: Channel[Int]) -> Result[Int]
  return inbox.recv(10)
end

def make() -> Channel[String]
  return Channel.new(2)
end

def main() -> Void
  ch = Channel.new(4)
end

