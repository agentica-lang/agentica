"""The VM HTTP client through a forward proxy, against tests/fixtures/http-proxy-peer.py.

The peer is a proxy that accepts only the absolute-form request target and two origin servers, on 127.0.0.1 with port 0.
It prints a line for each request it sees, so the tests assert the request line and the Host header as the proxy got
them, and the connection they came on.
"""
import base64
import socket

from tests.agentica_test import FIXTURES, PYTHON, Child, compile_agc, output_lines, run_vm, scaled, vm_environment

PEER = FIXTURES / "http-proxy-peer.py"

PROGRAM = """\
import HTTP from "std/http"

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) ->
      body = Result.unwrap_or(String.from_bytes(response.body), "<not UTF-8>")
      puts("#{response.status} #{body} via=#{HTTP.header_values(response.headers, "via")}")
    error(message) -> puts(message)
  end
end

def shown_error(r: Result[HttpClient]) -> Void
  case r
    ok(_) -> puts("a client was made")
    error(message) -> puts(message)
  end
end

def answered(r: Result[HttpResponse]) -> String
  case r
    ok(response) -> return "answered"
    error(message) -> return message
  end
end

# True when the error names the proxy that could not be reached.
def names_proxy(message: String, down: String) -> Bool
  return String.starts_with?(message, "http: cannot reach the proxy #{down}: ")
end

def chunks(into: Channel[Bytes]) -> Void
  into.send("0123456".bytes, 2000)
  into.send("789abcdef".bytes, 2000)
  into.close
end

def count(stream: HTTP.Stream) -> Int
  total = 0
  while true
    case stream.body.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  return total
end

def main() -> Void
  args = System.args()
  proxy = "http://127.0.0.1:#{args[0]}"
  a = "http://127.0.0.1:#{args[1]}"
  b = "http://127.0.0.1:#{args[2]}"
  options = HttpClientOptions(proxy: proxy)
  pool = HTTP.client(options).unwrap!
  show(HTTP.get(pool, "#{a}/hello"))
  show(HTTP.get(pool, "#{b}/hello?x=1"))
  show(HTTP.post(pool, "http://localhost:#{args[1]}/echo", "ping".bytes))
  # A second client with another proxy shares nothing with the first; an IPv6 literal on the default port has neither
  # the port in its Host nor in the absolute form.
  pool_two = HTTP.client(HttpClientOptions(proxy: "http://127.0.0.1:#{args[4]}")).unwrap!
  show(HTTP.get(pool_two, "#{a}/hello?two"))
  show(HTTP.get(pool, "#{a}/hello?one"))
  HTTP.close_client(pool_two)
  puts(answered(HTTP.get(pool, "http://[::1]/hello")))
  puts(HTTP.download(pool, "#{a}/big", "#{args[3]}/big.bin").unwrap!.status)
  puts(File.stat("#{args[3]}/big.bin").unwrap!.size_bytes)
  HTTP.close_client(pool)
  show(HTTP.get_response("#{b}/hello", options))
  show(HTTP.post_response("#{a}/echo", "abc".bytes, [], options))
  stream = HTTP.open("GET", "#{a}/big", "".bytes, [], options).unwrap!
  puts("#{stream.status} #{count(stream)}")
  into: Channel[Bytes] = Channel.new(2)
  Task.spawn(&chunks, into)
  show(HTTP.upload("PUT", "#{b}/echo", into, -1, [], options))
  conn = HTTP.start(b, options).unwrap!
  head = HTTP.send_request(conn, "GET", "/hello?start", "".bytes).unwrap!
  puts("#{head.status} #{HTTP.header_values(head.headers, "via")}")
  puts(String.from_bytes(HTTP.read_body(conn).unwrap!).unwrap!)
  HTTP.finish(conn)
  show(HTTP.get_response("https://127.0.0.1:#{args[1]}/", options))
  case HTTP.start("https://127.0.0.1:#{args[1]}", options)
    ok(_) -> puts("started")
    error(message) -> puts(message)
  end

  case HTTP.download(HTTP.client(options).unwrap!, "https://127.0.0.1:#{args[1]}/x", "#{args[3]}/x.bin")
    ok(_) -> puts("downloaded")
    error(message) -> puts(message)
  end

  # A proxy that is down: the error names it, whichever call reaches for it.
  down = "127.0.0.1:#{args[5]}"
  gone = HttpClientOptions(proxy: "http://#{down}")
  case HTTP.get_response("#{a}/hello", gone)
    ok(_) -> puts("answered")
    error(message) -> puts(names_proxy(message, down))
  end

  case HTTP.start(a, gone)
    ok(_) -> puts("started")
    error(message) -> puts(names_proxy(message, down))
  end

  case HTTP.download(HTTP.client(gone).unwrap!, "#{a}/big", "#{args[3]}/gone.bin")
    ok(_) -> puts("downloaded")
    error(message) -> puts(names_proxy(message, down))
  end

  shown_error(HTTP.client(HttpClientOptions(proxy: "ftp://127.0.0.1:1")))
  shown_error(HTTP.client(HttpClientOptions(proxy: "http://127.0.0.1:1?x=1")))
  shown_error(HTTP.client(HttpClientOptions(proxy: "http://127.0.0.1:1/path")))
  show(HTTP.get_response("#{a}/hello?direct"))
end
"""


def test_requests_go_to_the_proxy_in_absolute_form_on_one_pooled_connection(tmp_path, adopt):
    """Every call of the client reaches the proxy with the absolute-form target and the Host of the target: the pooled
    calls share one proxy connection even for two origins, a request to another name keeps its Host, and a call with
    no proxy does not touch it. https and a bad proxy are errors."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    proxy, first, second, proxy_two, _locked = peer.next_line().split()
    # A port that nothing listens on: bound and released.
    with socket.socket() as spare:
        spare.bind(("127.0.0.1", 0))
        down = str(spare.getsockname()[1])
    source = tmp_path / "proxy.agc"
    source.write_text(PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "proxy.agcb")
    result = run_vm(bytecode, env=vm_environment(), args=[proxy, first, second, str(tmp_path), proxy_two, down], timeout=scaled(120))
    assert result.code == 0, result.stderr
    assert output_lines(result.stdout) == [
        '200 hello from A /hello via=["1.1 proxy-peer"]',
        '200 hello from B /hello?x=1 via=["1.1 proxy-peer"]',
        '200 got 4 bytes: ping via=["1.1 proxy-peer"]',
        '200 hello from A /hello?two via=["1.1 proxy-peer"]',
        '200 hello from A /hello?one via=["1.1 proxy-peer"]',
        "answered",
        "200",
        "200000",
        '200 hello from B /hello via=["1.1 proxy-peer"]',
        '200 got 3 bytes: abc via=["1.1 proxy-peer"]',
        "200 200000",
        '200 got 16 bytes: 0123456789 via=["1.1 proxy-peer"]',
        '200 ["1.1 proxy-peer"]',
        "hello from B /hello?start",
        "http: https through a proxy is not supported yet",
        "http: https through a proxy is not supported yet",
        "http: https through a proxy is not supported yet",
        "true",
        "true",
        "true",
        "http: the proxy must be http://host:8080 or http://user:pass@host:8080, with no path or query",
        "http: the proxy must be http://host:8080 or http://user:pass@host:8080, with no path or query",
        "http: the proxy must be http://host:8080 or http://user:pass@host:8080, with no path or query",
        '200 hello from A /hello?direct via=[]',
    ]
    seen = [peer.next_line() for _ in range(12)]
    assert [line.split(" ", 2)[2] for line in seen] == [
        "GET http://127.0.0.1:%s/hello HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/hello?x=1 HTTP/1.1 | 127.0.0.1:%s" % (second, second),
        "POST http://localhost:%s/echo HTTP/1.1 | localhost:%s" % (first, first),
        "GET http://127.0.0.1:%s/hello?two HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/hello?one HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://[::1]/hello HTTP/1.1 | [::1]",
        "GET http://127.0.0.1:%s/big HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/hello HTTP/1.1 | 127.0.0.1:%s" % (second, second),
        "POST http://127.0.0.1:%s/echo HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/big HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "PUT http://127.0.0.1:%s/echo HTTP/1.1 | 127.0.0.1:%s" % (second, second),
        "GET http://127.0.0.1:%s/hello?start HTTP/1.1 | 127.0.0.1:%s" % (second, second),
    ]
    # The first three requests (two origins and a second name) used the pool's one connection to the proxy; the client
    # of the other proxy has a connection of its own, and the first client went on with its connection after it.
    connections = [line.split(" ")[1] for line in seen]
    assert len(set(connections[:3])) == 1
    assert connections[3] == "2:1" and connections[0].startswith("1:")
    assert connections[4] == connections[5] == connections[0]


AUTH_PROGRAM = """\
import HTTP from "std/http"

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{Result.unwrap_or(String.from_bytes(response.body), "<not UTF-8>")}")
    error(message) -> puts(message)
  end
end

def shown(r: Result[HttpClient]) -> Void
  case r
    ok(_) -> puts("a client was made")
    error(message) -> puts(message)
  end
end

def chunks(into: Channel[Bytes]) -> Void
  into.send("0123456".bytes, 2000)
  into.close
end

# The same five calls, each ending in the one line it prints: a response or the error of the call.
def calls(proxy: String, a: String, dir: String, tag: String) -> Void
  options = HttpClientOptions(proxy: proxy)
  pool = HTTP.client(options).unwrap!
  show(HTTP.get(pool, "#{a}/hello?#{tag}"))
  HTTP.close_client(pool)
  show(HTTP.post_response("#{a}/echo", "abc".bytes, [], options))
  case HTTP.download(HTTP.client(options).unwrap!, "#{a}/hello", "#{dir}/#{tag}.bin")
    ok(done) -> puts("download #{done.status}")
    error(message) -> puts(message)
  end

  case HTTP.open("GET", "#{a}/hello", "".bytes, [], options)
    ok(stream) -> puts("open #{stream.status}")
    error(message) -> puts(message)
  end

  into: Channel[Bytes] = Channel.new(2)
  Task.spawn(&chunks, into)
  show(HTTP.upload("PUT", "#{a}/echo", into, -1, [], options))
  case HTTP.start(a, options)
    ok(conn) ->
      case HTTP.send_request(conn, "GET", "/hello?#{tag}", "".bytes)
        ok(head) -> puts("start #{head.status}")
        error(message) -> puts(message)
      end

      HTTP.finish(conn)
    error(message) -> puts(message)
  end
end

def main() -> Void
  args = System.args()
  locked = "127.0.0.1:#{args[0]}"
  a = "http://127.0.0.1:#{args[1]}"
  dir = args[2]
  calls("http://us%40er:p%3Ass%2Fw@#{locked}", a, dir, "good")
  puts("-- the first colon ends the user, a later one is the password")
  show(HTTP.get_response("#{a}/hello?colon", HttpClientOptions(proxy: "http://us%40er:p:ss%2Fw@#{locked}")))
  puts("-- a wrong password")
  calls("http://us%40er:hunter2@#{locked}", a, dir, "wrong")
  puts("-- no user info")
  calls("http://#{locked}", a, dir, "none")
  puts("-- a 407 ends the pooled connection")
  pool = HTTP.client(HttpClientOptions(proxy: "http://#{locked}")).unwrap!
  show(HTTP.get(pool, "#{a}/hello?first"))
  show(HTTP.get(pool, "#{a}/hello?second"))
  HTTP.close_client(pool)
  puts("-- the caller's own header wins")
  mine = [Header(name: "Proxy-Authorization", value: args[3])]
  show(HTTP.post_response("#{a}/echo", "mine".bytes, mine, HttpClientOptions(proxy: "http://#{locked}")))
  puts("-- printing a connection shows no password, and the origin never got a Proxy-Authorization header")
  conn = HTTP.start(a, HttpClientOptions(proxy: "http://us%40er:p%3Ass%2Fw@#{locked}")).unwrap!
  IO.inspect(conn)
  HTTP.finish(conn)
  show(HTTP.get_response("#{a}/seen"))
  puts("-- a bad login or a bad proxy never quotes the user info")
  shown(HTTP.client(HttpClientOptions(proxy: "http://%zz:hunter2@127.0.0.1:1")))
  shown(HTTP.client(HttpClientOptions(proxy: "http://a%3Ab:hunter2@127.0.0.1:1")))
  shown(HTTP.client(HttpClientOptions(proxy: "http://@127.0.0.1:1")))
  shown(HTTP.client(HttpClientOptions(proxy: "http://:hunter2@127.0.0.1:1")))
  shown(HTTP.client(HttpClientOptions(proxy: "http://us:hunter2@127.0.0.1:1/path")))
  shown(HTTP.client(HttpClientOptions(proxy: "ftp://us:hunter2@127.0.0.1:1")))
  puts("-- a proxy that is down")
  case HTTP.get_response("#{a}/hello", HttpClientOptions(proxy: "http://us:hunter2@127.0.0.1:#{args[4]}"))
    ok(_) -> puts("answered")
    error(message) -> puts(String.starts_with?(message, "http: cannot reach the proxy 127.0.0.1:#{args[4]}: "))
  end
end
"""

LOGIN = "Basic " + base64.b64encode(b"us@er:p:ss/w").decode()


def test_the_user_info_of_the_proxy_is_its_basic_login_and_a_407_names_the_proxy_only(tmp_path, adopt):
    """The user info is percent-decoded into one Proxy-Authorization header that only the proxy sees, for each call; a
    wrong or missing login is a 407 error that names the proxy and never the user info; no output, error or trace
    holds the password."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    _proxy, first, _second, _proxy_two, locked = peer.next_line().split()
    with socket.socket() as spare:
        spare.bind(("127.0.0.1", 0))
        down = str(spare.getsockname()[1])
    source = tmp_path / "auth.agc"
    source.write_text(AUTH_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "auth.agcb")
    trace = tmp_path / "trace.log"
    env = vm_environment({"AGENTICA_VM_TRACE": "io,tls,sched", "AGENTICA_VM_TRACE_FILE": str(trace)})
    result = run_vm(bytecode, env=env, args=[locked, first, str(tmp_path), LOGIN, down], timeout=scaled(120))
    assert result.code == 0, result.stderr
    name = "127.0.0.1:" + locked
    denied = [
        "http: the proxy %s refused the credentials (407)" % name,
        "http: the proxy %s refused the credentials (407)" % name,
        "http: the proxy %s refused the credentials (407)" % name,
        "http: the proxy %s refused the credentials (407)" % name,
        "http: the proxy %s refused the credentials (407)" % name,
        "http: the proxy %s refused the credentials (407)" % name,
    ]
    asked = [line.replace("refused the credentials", "requires credentials") + ": put user:password in the proxy URL"
             for line in denied]
    granted = ["200 hello from A /hello?good", "200 got 3 bytes: abc", "download 200", "open 200", "200 got 7 bytes: 0123456",
               "start 200"]
    bad_login = "http: the proxy user info must be user:password in percent-encoding, and the user cannot hold a colon"
    bad_proxy = "http: the proxy must be http://host:8080 or http://user:pass@host:8080, with no path or query"
    lines = output_lines(result.stdout)
    # A printed connection holds its proxy without the user info (the login is in a channel, which prints opaque).
    shown = lines[lines.index("-- printing a connection shows no password, and the origin never got a Proxy-Authorization header") + 1]
    assert shown.startswith("Connection(") and 'proxy: "http://127.0.0.1:%s"' % locked in shown, shown
    assert "login: <Channel>" in shown, shown
    lines = [line if line != shown else "<INSPECT>" for line in lines]
    assert lines == [
        *granted,
        "-- the first colon ends the user, a later one is the password",
        "200 hello from A /hello?colon",
        "-- a wrong password",
        *denied,
        "-- no user info",
        *asked,
        "-- a 407 ends the pooled connection",
        asked[0],
        asked[0],
        "-- the caller's own header wins",
        "200 got 4 bytes: mine",
        "-- printing a connection shows no password, and the origin never got a Proxy-Authorization header",
        "<INSPECT>",
        "200 seen []",
        "-- a bad login or a bad proxy never quotes the user info",
        bad_login,
        bad_login,
        bad_login,
        bad_login,
        bad_proxy,
        bad_proxy,
        "-- a proxy that is down",
        "true",
    ]
    raw = [peer.next_line() for _ in range(22)]
    seen = [line.split(" ", 2)[2] for line in raw]
    # Every request of the good login (and the colon form) carried the one header; the wrong login and the missing one
    # went out with their own (or none) and were told 407.
    assert all(line.endswith(" | " + LOGIN) for line in seen[:7]), seen
    assert all(" | Basic " in line and not line.endswith(LOGIN) for line in seen[7:13]), seen
    assert all(line.endswith(" | -") for line in seen[13:19]), seen
    assert all(line.endswith(" | -") for line in seen[19:21]), seen
    # The 407 closed the pooled connection, so the second call came on a new one.
    assert raw[19].split(" ")[1] != raw[20].split(" ")[1], raw
    assert seen[21].endswith(" | " + LOGIN)
    assert all(" HTTP/1.1 | 127.0.0.1:%s | " % first in line for line in seen if "http://127.0.0.1:%s/" % first in line)
    # The password is in no output, no error and no trace; the origin never saw a Proxy-Authorization header (a proxy
    # keeps it), and the request target holds no user info.
    everything = result.stdout + result.stderr + trace.read_text(encoding="utf-8", errors="replace")
    for secret in ("hunter2", "p:ss", "p%3Ass", "ss/w", "ss%2Fw", "us@er", "us%40er"):
        assert secret not in everything, secret
    assert not any("@" in line.split(" ")[1] for line in seen if line.startswith(("GET", "PUT", "POST")))
