"""std/socks and the HTTP client through a SOCKS5 proxy, against tests/fixtures/socks5-peer.py.

The peer is an open SOCKS5 proxy, one that asks for a login, a plain origin and a TLS origin, on 127.0.0.1 with port 0.
It prints a line for each CONNECT, so the tests assert the login methods offered and the address type and address the
client sent.
"""
import socket

from tests.agentica_test import FIXTURES, PYTHON, Child, compile_agc, output_lines, run_vm, scaled, vm_environment

PEER = FIXTURES / "socks5-peer.py"
# The error of a TCP read that runs out of time.
TIMEOUT = "network: operation timed out"

PROGRAM = """\
import HTTP from "std/http"
import Socks from "std/socks"

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{String.from_bytes(response.body).unwrap!}")
    error(message) -> puts(message)
  end
end

def connected(r: Result[Socket]) -> Void
  case r
    ok(socket) ->
      puts("connected")
      TCP.close(socket)
    # The error of a proxy that is down has the lines of the system error after its first.
    error(message) -> puts(message.split("\\n")[0])
  end
end

# Everything the socket gives until the other end closes.
def read_all(socket: Socket) -> String
  data = "".bytes
  while true
    piece = TCP.recv_bytes(socket, 65536, 5000).unwrap!
    break if piece.empty?

    data = data + piece
  end

  String.from_bytes(data).unwrap!
end

def started(origin: String, options: HttpClientOptions) -> Void
  case HTTP.start(origin, options)
    ok(conn) ->
      head = HTTP.send_request(conn, "GET", "/start", "".bytes).unwrap!
      puts("start #{head.status} #{String.from_bytes(HTTP.read_body(conn).unwrap!).unwrap!} #{conn.options.proxy}")
      HTTP.finish(conn)
    error(message) -> puts(message)
  end
end

def main() -> Void
  args = System.args()
  open = "127.0.0.1:#{args[0]}"
  locked = "127.0.0.1:#{args[1]}"
  a = args[2].to_int!
  c = args[3]
  context = TLS.client_context(TlsClientOptions(ca_file: args[4])).unwrap!
  login = "us%40er:p%3Ass%2Fw"

  puts("-- Socks.connect")
  case Socks.connect("socks5h://#{open}", "example.test", a, 5000)
    ok(socket) ->
      _ = TCP.send_bytes(socket, "GET /raw HTTP/1.0\\r\\nHost: raw\\r\\n\\r\\n".bytes, 5000)
      puts(read_all(socket).split("\\r\\n\\r\\n")[1])
      TCP.close(socket)
    error(message) -> puts(message)
  end
  connected(Socks.connect("socks5://#{open}", "127.0.0.1", a, 5000))
  connected(Socks.connect("socks5h://#{open}/", "::1", a, 5000))
  for code in 1..9
    connected(Socks.connect("socks5h://#{open}", "10.0.0.1", code, 5000))
  end
  connected(Socks.connect("socks5h://#{open}", "10.0.0.1", 10, 5000))
  connected(Socks.connect("socks5h://#{open}", "10.0.0.1", 11, 300))
  connected(Socks.connect("socks5://#{open}", "example.test", a, 5000))

  puts("-- logins")
  connected(Socks.connect("socks5h://#{login}@#{locked}", "example.test", a, 5000))
  connected(Socks.connect("socks5h://#{locked}", "example.test", a, 5000))
  connected(Socks.connect("socks5h://us%40er:hunter2@#{locked}", "example.test", a, 5000))

  puts("-- bad proxies")
  connected(Socks.connect("socks4://#{open}", "example.test", a, 5000))
  connected(Socks.connect("socks5h://#{open}/path", "example.test", a, 5000))
  connected(Socks.connect("socks5h://user@#{open}", "example.test", a, 5000))
  connected(Socks.connect("socks5h://127.0.0.1:99999", "example.test", a, 5000))
  connected(Socks.connect("socks5h://127.0.0.1:#{args[5]}", "example.test", a, 5000))

  puts("-- HTTP")
  proxy = "socks5h://#{open}"
  show(HTTP.get_response("http://example.test:#{a}/hello", HttpClientOptions(proxy: proxy)))
  show(HTTP.get_response("http://[::1]:#{a}/v6", HttpClientOptions(proxy: proxy)))
  pool = HTTP.client(HttpClientOptions(proxy: "socks5h://#{login}@#{locked}")).unwrap!
  show(HTTP.get(pool, "http://example.test:#{a}/one"))
  show(HTTP.get(pool, "http://other.test:#{a}/two"))
  HTTP.close_client(pool)
  started("http://example.test:#{a}", HttpClientOptions(proxy: "socks5h://#{login}@#{locked}"))
  case HTTP.download(HTTP.client(HttpClientOptions(proxy: proxy)).unwrap!, "http://example.test:#{a}/file", args[6])
    ok(done) -> puts("download #{done.status} #{File.read_text(args[6]).unwrap!}")
    error(message) -> puts(message)
  end
  show(HTTP.get_response("https://localhost:#{c}/secure", HttpClientOptions(proxy: proxy, tls: some(context))))
  secure = HTTP.client(HttpClientOptions(proxy: "socks5h://#{login}@#{locked}", tls: some(context))).unwrap!
  show(HTTP.get(secure, "https://localhost:#{c}/pooled"))
  HTTP.close_client(secure)
  started("https://localhost:#{c}", HttpClientOptions(proxy: proxy, tls: some(context)))
  # The proxy reaches the same origin for any name, and its certificate names localhost only.
  show(HTTP.get_response("https://wrong.test:#{c}/", HttpClientOptions(proxy: proxy, tls: some(context))))
  show(HTTP.get_response("http://example.test:3/", HttpClientOptions(proxy: proxy)))
  show(HTTP.get_response("http://example.test:#{a}/", HttpClientOptions(proxy: "socks5h://#{locked}")))
  case HTTP.client(HttpClientOptions(proxy: "socks5h://#{open}/x"))
    ok(_) -> puts("a client was made")
    error(message) -> puts(message)
  end
end
"""


def test_connections_and_http_requests_go_through_a_socks5_proxy(tmp_path, adopt):
    """Socks.connect and every HTTP call through a SOCKS5 proxy: a name goes to the proxy with socks5h, an IP literal
    as an address, the login goes in the sub-negotiation and nowhere else, each reply code and a bad answer is an error
    that names the proxy and the target (as is a proxy that closes or goes silent mid-handshake), and a request inside
    is written as with no proxy."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    open_port, locked_port, origin, secure = peer.next_line().split()
    with socket.socket() as spare:
        spare.bind(("127.0.0.1", 0))
        down = str(spare.getsockname()[1])
    source = tmp_path / "socks.agc"
    source.write_text(PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "socks.agcb")
    ca = str(FIXTURES / "tls" / "ca.pem")
    file = str(tmp_path / "file.txt")
    args = [open_port, locked_port, origin, secure, ca, down, file]
    result = run_vm(bytecode, env=vm_environment(), args=args, timeout=scaled(120))
    assert result.code == 0, result.stderr

    open_name = "127.0.0.1:" + open_port
    locked_name = "127.0.0.1:" + locked_port
    bad = ("socks: the proxy must be socks5://host:1080 or socks5h://host:1080, with an optional user:password@ and no "
           "path or query")
    refused = "socks: the proxy %s refused the connection to 10.0.0.1:%%d: %%s" % open_name
    reasons = ["general failure (1)", "not allowed by the proxy's rules (2)", "network unreachable (3)",
               "host unreachable (4)", "connection refused (5)", "TTL expired (6)", "command not supported (7)",
               "address type not supported (8)"]
    lines = output_lines(result.stdout)
    assert lines[:27] == [
        "-- Socks.connect",
        "hello from A /raw host=raw",
        "connected",
        "connected",
        *[refused % (code, reason) for code, reason in zip(range(1, 9), reasons)],
        "socks: the proxy %s sent an answer that is not SOCKS5 to the connection to 10.0.0.1:9" % open_name,
        "socks: the connection to 10.0.0.1:10 through the proxy %s failed: the proxy closed the connection" % open_name,
        "socks: the connection to 10.0.0.1:11 through the proxy %s failed: %s" % (open_name, TIMEOUT),
        "socks: socks5:// cannot resolve example.test:%s here yet: use socks5h://" % origin,
        "-- logins",
        "connected",
        "socks: the proxy %s requires credentials: put user:password in the proxy URL" % locked_name,
        "socks: the proxy %s refused the credentials" % locked_name,
        "-- bad proxies",
        bad,
        bad,
        "socks: the proxy user info must be user:password in percent-encoding, each of 1 to 255 bytes",
        bad,
        lines[25],
        "-- HTTP",
    ]
    assert lines[25].startswith("socks: cannot reach the proxy 127.0.0.1:%s: " % down)
    assert lines[27:] == [
        "200 hello from A /hello host=example.test:%s" % origin,
        "200 hello from A /v6 host=[::1]:%s" % origin,
        "200 hello from A /one host=example.test:%s" % origin,
        "200 hello from A /two host=other.test:%s" % origin,
        "start 200 hello from A /start host=example.test:%s socks5h://%s" % (origin, locked_name),
        "download 200 hello from A /file host=example.test:%s" % origin,
        "200 hello from C /secure host=localhost:%s" % secure,
        "200 hello from C /pooled host=localhost:%s" % secure,
        "start 200 hello from C /start host=localhost:%s socks5h://%s" % (secure, open_name),
        "network: TLS handshake failed (certificate verify failed: hostname mismatch)",
        "socks: the proxy %s refused the connection to example.test:3: network unreachable (3)" % open_name,
        "socks: the proxy %s requires credentials: put user:password in the proxy URL" % locked_name,
        bad,
    ]

    # What the proxies saw: the methods offered, the login, the address type (1 IPv4, 3 a name, 4 IPv6) and the
    # address. A name went as a name, a literal as an address, and the login only to the locked proxy.
    peer.close_stdin()
    assert peer.wait() == 0
    seen = [line.split(" ", 1)[1] for line in output_lines(peer.stdout_text()) if line.startswith("SAW")]
    assert seen[:3] == [
        "open 0 - 3 example.test %s" % origin,
        "open 0 - 1 127.0.0.1 %s" % origin,
        "open 0 - 4 ::1 %s" % origin,
    ]
    assert seen[3:14] == ["open 0 - 1 10.0.0.1 %d" % code for code in range(1, 12)]
    assert seen[14:17] == [
        "locked 0,2 us@er:p:ss/w 3 example.test %s" % origin,
        "locked 0 - refused",
        "locked 0,2 us@er:hunter2 refused",
    ]
    assert "open 0 - 4 ::1 %s" % origin in seen[17:]
    assert "locked 0,2 us@er:p:ss/w 3 other.test %s" % origin in seen[17:]
    assert "open 0 - 3 localhost %s" % secure in seen[17:]
    for secret in ("p:ss", "p%3Ass", "hunter2", "us@er", "us%40er"):
        assert secret not in result.stdout + result.stderr, secret
