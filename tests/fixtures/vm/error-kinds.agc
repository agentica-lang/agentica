# The kind and the code of one real failure per family of the C builtins (#671): an OS error has the errno as its code
# (ENOENT 2, EEXIST 17 and EISDIR 21 are the same on Linux, macOS and Windows) and the rest no code.
# ECONNREFUSED differs between systems, so only its presence is shown. The HTTP codec (HttpWire, reached through
# std/http) gives http.too_large for every size limit, with 431 for a head and 413 for a body, and http.protocol
# for the rest.
import HTTP from "std/http"

struct Row
  name: String
end

# The whole response of any method on a connection of its own, as the removed pooled `HTTP.request` gave it.
def request(
  options: HTTP.ClientOptions,
  method: String,
  url: String,
  body: Bytes,
  headers: List[HTTP.Header] = [],
) -> Result[HTTP.Response]
  stream = try HTTP.open(method, url, body, headers, options)
  pieces: List[Bytes] = []
  open = true
  while open
    case stream.body.recv(5000)
      ok(piece) -> pieces = pieces.push(piece)
      error(_) -> open = false
    end
  end
  ok(HTTP.Response(status: stream.status, headers: stream.headers, body: Bytes.concat(pieces)))
end

def at(dir: String, name: String) -> String = Result.unwrap!(Path.join([dir, name]))

def show[T](label: String, family: String, result: Result[T]) -> Void
  case result
    ok(_) -> puts("#{label}: ok")
    error(e) ->
      code = case e.code
        some(n) -> n.to_s
        none -> "none"
      end

      puts("#{label}: #{e.kind} code=#{code} #{family}=#{e.is_a?(family)}")
  end
end

def coded[T](label: String, result: Result[T]) -> Void
  case result
    ok(_) -> puts("#{label}: ok")
    error(e) -> puts("#{label}: #{e.kind} code=#{e.code.some?}")
  end
end

def boom(n: Int) -> Result[Int] = ok(10 / n)

# Two sends of 600000 bytes and no newline: the reader's line goes over its limit of 1048576 bytes.
def send_long(socket: TCP.Socket) -> Result[Void]
  chunk = "x" * 600000
  try TCP.send(socket, chunk, 5000)
  TCP.send(socket, chunk, 5000)
end

# Answers each request with the next reply, one connection each.
def answer(listener: TCP.Listener, replies: List[String]) -> Void
  for reply in replies
    socket = Result.unwrap!(TCP.accept(listener, 5000))
    line = Result.unwrap!(TCP.read_line(socket, 5000))
    while line != ""
      line = Result.unwrap!(TCP.read_line(socket, 5000))
    end
    _ = TCP.send(socket, reply, 5000)
    TCP.close(socket)
  end
end

def http_rows() -> Void
  options = HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 16)
  pool = options
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  url = "http://127.0.0.1:#{TCP.local_port(listener)}/"
  replies = [
    "HTTP/1.1 200 OK\r\nX-Long: #{"a" * 9000}\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\n#{"X-Many: 1\r\n" * 101}Content-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;#{"e" * 9000}\r\nx\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n28\r\n#{"b" * 40}\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n#{"c" * 40}",
    "HTTP/1.1 2x0 OK\r\nContent-Length: 0\r\n\r\n",
  ]

  server = Task.spawn(-> { answer(listener, replies) })
  show("response line too large", "http", HTTP.get_response(url, pool))
  show("response headers too many", "http", HTTP.get_response(url, pool))
  show("chunk line too large", "http", HTTP.get_response(url, pool))
  show("response body too large", "http", HTTP.get_response(url, pool))
  show("chunked body too large", "http", HTTP.get_response(url, pool))
  show("close-delimited body too large", "http", HTTP.get_response(url, pool))
  show("response head malformed", "http", HTTP.get_response(url, pool))
  long = [HTTP.Header(name: "X-Long", value: "a" * 9000)]
  show("request header line too large", "http", HTTP.post_response(url, "".bytes, long, pool))
  many: List[HTTP.Header] = []
  while List.size(many) < 101
    many = List.append(many, HTTP.Header(name: "X-Many", value: "1"))
  end
  show("request headers too many", "http", HTTP.post_response(url, "".bytes, many, pool))
  show("request body too large", "http", HTTP.post_response(url, "this body is over the limit".bytes, [], pool))
  show("request method malformed", "http", request(pool, "BAD METHOD", url, "".bytes))
  Task.await(server)
  TCP.close_listener(listener)
end

def main() -> Void
  dir: String = System.args()[0]
  file = at(dir, "file.txt")
  _ = File.write_text(file, "data", 60000)
  show("missing file", "io", File.read_text(at(dir, "missing.txt"), 60000))
  show("directory as file", "io", File.write_text(dir, "x", 60000))
  show("directory as text", "io", File.read_text(dir, 60000))
  show("existing file", "io", File.open(file, "create_private", 60000))
  show("invalid path", "io", File.read_text("", 60000))
  show("stat missing", "io", File.stat(at(dir, "missing.txt"), 60000))
  show("TLS ca_file", "io", TLS.client_context(TLS.ClientOptions(ca_file: at(dir, "missing.pem"))))
  identity = TLS.ServerOptions(cert_file: at(dir, "missing.pem"), key_file: at(dir, "missing.key"))
  show("TLS cert_file", "io", TLS.server_context(identity))
  show("bad timeout", "argument", File.read_text(file, 0))

  show("parse Int", "number", "12x".to_i)
  show("Int range", "number", "99999999999999999999".to_i)
  show("bad UTF-8", "text", String.from_bytes(Bytes.from_list([104, 255]).unwrap!))
  show("parse JSON", "json", JSON.parse("{"))
  show("decode JSON", "json", JSON.decode("[1]", Row))
  show("inflate", "zlib", Zlib.inflate("not zlib".bytes, 1000))
  show("environment", "system", System.env("AGENTICA_ERROR_KINDS_UNSET"))

  jobs: Channel[Int] = Channel.new(1)
  show("channel timeout", "channel", jobs.recv(10))
  jobs.close
  show("channel closed", "channel", jobs.recv(10))
  show("task crashed", "task", Task.await(Task.spawn(&boom, 0)))

  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  client = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  server = Result.unwrap!(TCP.accept(listener, 5000))
  TCP.close(server)
  show("end of input", "net", TCP.read_line(client, 5000))
  TCP.close(client)
  show("closed socket", "net", TCP.read_line(client, 5000))
  long = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  peer = Result.unwrap!(TCP.accept(listener, 5000))
  sender = Task.spawn(&send_long, peer)
  show("long line", "net", TCP.read_line(long, 5000))
  TCP.close(long)
  _ = Task.await(sender)
  TCP.close(peer)
  idle = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  show("read timeout", "net", TCP.read_line(idle, 30))
  TCP.close(idle)
  TCP.close_listener(listener)
  coded("refused", TCP.connect("127.0.0.1", port, 5000))
  show("no program", "process", Process.spawn("agentica-error-kinds-missing", [], Process.Options(timeout_ms: 5000)))
  http_rows()
end
