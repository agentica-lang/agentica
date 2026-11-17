NO_BODY = "".bytes

struct Frame
  head: Bytes = "GET".bytes
  tail: Bytes = NO_BODY
end

def send(body: Bytes = NO_BODY, separator: Bytes = "\r\n".bytes()) -> Int = body.length + separator.length

def main() -> Void
  puts(send())
  puts(Frame().head.length)
end
