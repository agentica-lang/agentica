## The SOCKS5 client of `std/socks` and `std/http`: the proxy URL and the handshake (RFC 1928, with the user and
## password login of RFC 1929) over a `TCP` connection.
##
## Import it with `import SocksWire from "std/internal/socks"`. Only a module of `std/` may import a module under
## `std/internal/`; `std/socks` gives `connect` to programs, and `std/http` reads the proxy URL of a client here.

import URI from "std/uri"

DEFAULT_PORT = 1080
VERSION = 5
NO_AUTH = 0
USER_PASSWORD = 2
NO_METHOD = 255
CONNECT = 1
IPV4 = 1
NAME = 3
IPV6 = 4
# The most bytes of a user, a password or a host name in the protocol: one length byte each.
MAX_FIELD = 255
BAD_PROXY = (
  "socks: the proxy must be socks5://host:1080 or socks5h://host:1080, with an optional user:password@ and no path " +
  "or query"
)
BAD_LOGIN = "socks: the proxy user info must be user:password in percent-encoding, each of 1 to 255 bytes"
# The texts of the reply codes 1 to 8 (RFC 1928 6).
REPLIES = [
  "general failure",
  "not allowed by the proxy's rules",
  "network unreachable",
  "host unreachable",
  "connection refused",
  "TTL expired",
  "command not supported",
  "address type not supported",
]

## A SOCKS5 proxy as its URL names it: where it is, whether the target's name goes to the proxy (`socks5h`) or is
## resolved here (`socks5`), and the login (an empty user for none).
export struct Proxy
  host: String
  port: Int
  remote_names: Bool
  user: String
  password: String
end

struct HostPort
  host: String
  port: Int
end

# The target as the CONNECT request carries it: the address type, the address bytes and the name for errors.
struct Target
  kind: Int
  address: Bytes
  port: Int
  name: String
end

struct Ip
  kind: Int
  address: Bytes
end

## The proxy of a `socks5://` or `socks5h://` URL. The error never quotes the URL, which may hold a password.
export def parse(url: String) -> Result[Proxy]
  remote = false
  rest = ""
  if url.start_with?("socks5h://")
    remote = true
    rest = url.slice(10, url.length - 10)
  elsif url.start_with?("socks5://")
    rest = url.slice(9, url.length - 9)
  else
    return error(BAD_PROXY)
  end

  if rest.end_with?("/")
    rest = rest.slice(0, rest.length - 1)
  end
  return error(BAD_PROXY) if rest.include?("/") or rest.include?("?") or rest.include?("#")

  user = ""
  password = ""
  at = last_index(rest, "@")
  if at >= 0
    login = try login_of(rest.slice(0, at))
    user = login[0]
    password = login[1]
    rest = rest.slice(at + 1, rest.length - at - 1)
  end

  where = try host_port(rest)
  ok(Proxy(host: where.host, port: where.port, remote_names: remote, user: user, password: password))
end

## True for a URL with a SOCKS scheme, which `parse` then reads.
export def socks?(url: String) -> Bool = url.start_with?("socks5://") or url.start_with?("socks5h://")

## A TCP connection to `host:port` through `proxy`, ready for the target's protocol, within `timeout_ms`. Every error
## names the proxy and the target, never the login.
export def connect(proxy: Proxy, host: String, port: Int, timeout_ms: Int) -> Result[Socket]
  deadline = Time.monotonic_ms + timeout_ms
  target = try address_of(proxy, host, port, deadline)
  socket = try reached(TCP.connect(proxy.host, proxy.port, timeout_ms), proxy)
  case handshake(socket, proxy, target, deadline)
    ok(_) -> ok(socket)
    error(message) ->
      TCP.close(socket)
      error(message)
  end
end

## The proxy's URL without the login, which is safe to print.
export def public_url(proxy: Proxy) -> String
  scheme = "socks5"
  if proxy.remote_names
    scheme = "socks5h"
  end

  "#{scheme}://#{name_of(proxy.host, proxy.port)}"
end

## `host:port` as errors name it, with brackets around an IPv6 literal.
export def name_of(host: String, port: Int) -> String
  return "[#{host}]:#{port}" if host.include?(":")

  "#{host}:#{port}"
end

def reached(connected: Result[Socket], proxy: Proxy) -> Result[Socket]
  case connected
    ok(socket) -> ok(socket)
    error(message) -> error("socks: cannot reach the proxy #{name_of(proxy.host, proxy.port)}: #{message}")
  end
end

def handshake(socket: Socket, proxy: Proxy, target: Target, deadline: Int) -> Result[Void]
  proxy_name = name_of(proxy.host, proxy.port)
  case steps(socket, proxy, target, deadline)
    ok(_) -> ok()
    error(message) ->
      return error(message) if message.start_with?("socks: ")

      error("socks: the connection to #{target.name} through the proxy #{proxy_name} failed: #{message}")
  end
end

# The greeting, the login when the proxy asks for it, and the CONNECT. An error that starts with `socks: ` is the
# proxy's answer; any other is the connection's (a timeout, a close) and `handshake` names both ends.
def steps(socket: Socket, proxy: Proxy, target: Target, deadline: Int) -> Result[Void]
  proxy_name = name_of(proxy.host, proxy.port)
  methods = [NO_AUTH]
  if proxy.user != ""
    methods = [NO_AUTH, USER_PASSWORD]
  end

  try send(socket, octets([VERSION, methods.size]) + octets(methods), deadline)
  chosen = try read(socket, 2, deadline)
  return error(bad_answer(proxy_name, target)) if chosen[0] != VERSION

  case chosen[1]
    0 -> nil
    2 ->
      return error(bad_answer(proxy_name, target)) if proxy.user == ""

      try login(socket, proxy, deadline)
    255 ->
      if proxy.user == ""
        return error("socks: the proxy #{proxy_name} requires credentials: put user:password in the proxy URL")
      end

      return error("socks: the proxy #{proxy_name} accepts none of the login methods offered")
    _ -> return error(bad_answer(proxy_name, target))
  end

  port = octets([target.port / 256, target.port % 256])
  request = octets([VERSION, CONNECT, 0, target.kind]) + target.address + port
  try send(socket, request, deadline)
  head = try read(socket, 4, deadline)
  return error(bad_answer(proxy_name, target)) if head[0] != VERSION

  if head[1] != 0
    return error("socks: the proxy #{proxy_name} refused the connection to #{target.name}: #{reply_text(head[1])}")
  end

  # The address the proxy bound for the connection: read and dropped, so the target's bytes come next.
  case head[3]
    1 -> _ = try read(socket, 4 + 2, deadline)
    4 -> _ = try read(socket, 16 + 2, deadline)
    3 ->
      size = try read(socket, 1, deadline)
      _ = try read(socket, size[0] + 2, deadline)
    _ -> return error(bad_answer(proxy_name, target))
  end
  ok()
end

# The user and password sub-negotiation (RFC 1929): status 0 lets the connection go on.
def login(socket: Socket, proxy: Proxy, deadline: Int) -> Result[Void]
  user = proxy.user.bytes
  password = proxy.password.bytes
  request = octets([1, user.length]) + user + octets([password.length]) + password
  try send(socket, request, deadline)
  answer = try read(socket, 2, deadline)
  return error("socks: the proxy #{name_of(proxy.host, proxy.port)} refused the credentials") if answer[1] != 0

  ok()
end

def bad_answer(proxy_name: String, target: Target) -> String
  "socks: the proxy #{proxy_name} sent an answer that is not SOCKS5 to the connection to #{target.name}"
end

def reply_text(code: Int) -> String
  return "#{REPLIES[code - 1]} (#{code})" if code >= 1 and code <= REPLIES.size

  "reply #{code}"
end

def send(socket: Socket, data: Bytes, deadline: Int) -> Result[Void] = TCP.send_bytes(socket, data, try left(deadline))

# Bytes from values that the protocol keeps in 0 to 255.
def octets(values: List[Int]) -> Bytes = Bytes.from_list(values).unwrap!

# Exactly `count` bytes; the proxy closing before them is an error.
def read(socket: Socket, count: Int, deadline: Int) -> Result[Bytes]
  pieces: List[Bytes] = []
  got = 0
  while got < count
    piece = try TCP.recv_bytes(socket, count - got, try left(deadline))
    return error("the proxy closed the connection") if piece.empty?

    pieces = pieces.push(piece)
    got += piece.length
  end

  ok(Bytes.concat(pieces))
end

def left(deadline: Int) -> Result[Int]
  rest = deadline - Time.monotonic_ms
  return error("timed out") if rest <= 0

  ok(rest)
end

# The target for the CONNECT: an IP literal as its address, a name as itself through `socks5h`, or resolved here
# through `socks5`.
def address_of(proxy: Proxy, host: String, port: Int, deadline: Int) -> Result[Target]
  name = name_of(host, port)
  case ip_bytes(host)
    some(found) -> return ok(Target(kind: found.kind, address: found.address, port: port, name: name))
    none -> nil
  end

  if proxy.remote_names
    data = host.bytes
    return error("socks: the host name of #{name} is longer than 255 bytes") if data.length > MAX_FIELD

    return ok(Target(kind: NAME, address: octets([data.length]) + data, port: port, name: name))
  end

  resolved(host, port, deadline)
end

# The target of `socks5` for a name, which needs a resolver here: until `DNS.lookup` (#1398) lands, the name goes to
# `socks5h`.
def resolved(host: String, port: Int, deadline: Int) -> Result[Target]
  _ = deadline
  error("socks: socks5:// cannot resolve #{name_of(host, port)} here yet: use socks5h://")
end

# The bytes of an IPv4 or IPv6 literal, or none for a name.
def ip_bytes(host: String) -> Optional[Ip]
  case ipv4(host)
    ok(values) -> return some(Ip(kind: IPV4, address: octets(values)))
    error(_) -> nil
  end
  return none if not host.include?(":")

  case ipv6(host)
    ok(values) -> some(Ip(kind: IPV6, address: octets(values)))
    error(_) -> none
  end
end

# The four values of a dotted IPv4 literal; the error is never shown.
def ipv4(host: String) -> Result[List[Int]]
  parts = host.split(".")
  return error("not IPv4") if parts.size != 4

  values: List[Int] = []
  for part in parts
    return error("not IPv4") if part.empty? or part.length > 3 or not digits?(part)

    value = try part.to_i
    return error("not IPv4") if value > 255

    values = values.push(value)
  end

  ok(values)
end

# The 16 bytes of an IPv6 literal: hex groups with at most one `::`, and an IPv4 tail as the last two groups. The
# error is never shown.
def ipv6(host: String) -> Result[List[Int]]
  front_text = host
  back_text = ""
  gap = false
  case host.index_of("::")
    some(at) ->
      gap = true
      front_text = host.slice(0, at)
      back_text = host.slice(at + 2, host.length - at - 2)
    none -> nil
  end
  return error("not IPv6") if back_text.include?("::")

  front = try groups_of(front_text)
  back = try groups_of(back_text)
  missing = 8 - front.size - back.size
  return error("not IPv6") if missing < 0 or (not gap and missing != 0) or (gap and missing < 1)

  groups = front
  for _ in 0...missing
    groups = groups.push(0)
  end
  for group in back
    groups = groups.push(group)
  end

  ok(groups.flat_map do |group| [group / 256, group % 256] end)
end

# The 16-bit groups of one side of `::`; an IPv4 tail counts as two groups.
def groups_of(text: String) -> Result[List[Int]]
  groups: List[Int] = []
  return ok(groups) if text.empty?

  parts = text.split(":")
  for index in 0...parts.size
    part = parts[index]
    if index == parts.size - 1 and part.include?(".")
      values = try ipv4(part)
      groups = groups.push(values[0] * 256 + values[1]).push(values[2] * 256 + values[3])
    else
      return error("not IPv6") if part.empty? or part.length > 4

      groups = groups.push(try hex(part))
    end
  end

  ok(groups)
end

def hex(text: String) -> Result[Int]
  value = 0
  for char in text.downcase.split("")
    case "0123456789abcdef".index_of(char)
      some(digit) -> value = value * 16 + digit
      none -> return error("not hex")
    end
  end

  ok(value)
end

def digits?(text: String) -> Bool = text.split("").all? do |char| "0123456789".include?(char) end

def host_port(text: String) -> Result[HostPort]
  return error(BAD_PROXY) if text.empty?

  host = text
  port_text = ""
  if text.start_with?("[")
    close = text.index_of("]").unwrap_or(-1)
    return error(BAD_PROXY) if close < 0

    host = text.slice(1, close - 1)
    after = text.slice(close + 1, text.length - close - 1)
    if after != ""
      return error(BAD_PROXY) if not after.start_with?(":")

      port_text = after.slice(1, after.length - 1)
    end
  else
    colon = last_index(text, ":")
    if colon >= 0
      host = text.slice(0, colon)
      port_text = text.slice(colon + 1, text.length - colon - 1)
      return error(BAD_PROXY) if host.include?(":")
    end
  end

  return error(BAD_PROXY) if host.empty?
  return ok(HostPort(host: host, port: DEFAULT_PORT)) if port_text == ""
  return error(BAD_PROXY) if not digits?(port_text)

  port = port_text.to_i.unwrap_or(0)
  return error(BAD_PROXY) if port < 1 or port > 65535

  ok(HostPort(host: host, port: port))
end

# The user and the password of `user:password`, percent-decoded, each 1 to 255 bytes.
def login_of(info: String) -> Result[List[String]]
  colon = info.index_of(":").unwrap_or(info.length)
  user = try decoded(info.slice(0, colon))
  password = ""
  if colon < info.length
    password = try decoded(info.slice(colon + 1, info.length - colon - 1))
  end

  return error(BAD_LOGIN) if user.empty? or password.empty?
  return error(BAD_LOGIN) if user.bytesize > MAX_FIELD or password.bytesize > MAX_FIELD

  ok([user, password])
end

def decoded(text: String) -> Result[String]
  case URI.decode_uri_component(text)
    ok(found) -> ok(found)
    error(_) -> error(BAD_LOGIN)
  end
end

def last_index(text: String, part: String) -> Int
  found = -1
  for position in 0...text.length
    if text.slice(position, 1) == part
      found = position
    end
  end

  found
end
