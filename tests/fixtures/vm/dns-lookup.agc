# DNS.lookup without a resolver query: IP literals give themselves (an IPv6 one in its short form), and the refusals
# come before any lookup. A name longer than libuv's IDNA buffer is refused by libuv itself, with a system error text
# that differs by system, so only its kind is printed.
def main() -> Void
  IO.inspect(DNS.lookup("127.0.0.1"))
  IO.inspect(DNS.lookup("::1", 5000))
  IO.inspect(DNS.lookup("2001:DB8:0:0:0:0:0:1"))
  IO.inspect(DNS.lookup(""))
  IO.inspect(DNS.lookup("local#{String.from_code(0)}host"))
  IO.inspect(DNS.lookup("localhost", 0))
  IO.inspect(DNS.lookup("localhost", -1))
  IO.inspect(DNS.lookup("a" * 300).ok?)
end
