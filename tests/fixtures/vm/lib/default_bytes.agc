# The Bytes constants of the defaults below. A caller in another file leaves the argument out and gets the bytes,
# because the default is the value written where it is declared.
NO_BODY = "".bytes
CRLF = "\r\n".bytes

struct Frame
  head: Bytes = "GET".bytes
  tail: Bytes = CRLF
end

def send(body: Bytes = NO_BODY, separator: Bytes = "\r\n".bytes()) -> String = "#{body.length} #{separator.to_a}"
