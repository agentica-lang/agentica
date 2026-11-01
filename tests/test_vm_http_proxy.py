"""The VM HTTP client through a forward proxy, against tests/fixtures/http-proxy-peer.py.

The peer is a proxy that accepts only the absolute-form request target and two origin servers, on 127.0.0.1 with port 0.
It prints a line for each request it sees, so the tests assert the request line and the Host header as the proxy got
them, and the connection they came on.
"""
import base64
import socket

from tests.agentica_test import (FIXTURES, PYTHON, WINDOWS, Child, compile_agc, host_only, output_lines, run_vm, scaled,
                                 vm_environment)

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
    no proxy does not touch it. A bad proxy is an error."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    proxy, first, second, proxy_two = peer.next_line().split()[:4]
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
    _proxy, first, _second, _proxy_two, locked = peer.next_line().split()[:5]
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


ENV_PROGRAM = """\
import HTTP from "std/http"

def main() -> Void
  for url in System.args()
    puts("#{url} => [#{HTTP.proxy_from_env(url)}]")
  end
end
"""

# Every variable that proxy_from_env reads: a run starts from none of them, whatever the caller's shell has.
ENV_NAMES = ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY", "REQUEST_METHOD")

# (environment, [(url, the proxy it gets)]): one VM run for each environment.
ENV_CASES = [
    # A scheme-less https proxy gets http://; the no_proxy list has every kind of entry.
    (
        {
            "http_proxy": " http://proxy.local:3128/ ",
            "HTTPS_PROXY": "secure.local:3129",
            "NO_PROXY": " .internal.test, example.org:8080 ,10.0.0.0/8,[::1], 192.168.1.5,localhost,,",
        },
        [
            ("http://example.com/", "http://proxy.local:3128/"),
            ("https://example.com/", "http://secure.local:3129"),
            ("http://a.internal.test/x", ""),
            ("http://internal.test/", ""),
            ("http://notinternal.test/", "http://proxy.local:3128/"),
            ("http://example.org:8080/", ""),
            ("http://www.example.org:8080/", ""),
            ("http://example.org/", "http://proxy.local:3128/"),
            ("http://10.2.3.4/", ""),
            ("http://11.2.3.4/", "http://proxy.local:3128/"),
            ("http://[::1]/", ""),
            ("http://192.168.1.5/", ""),
            ("http://192.168.1.50/", "http://proxy.local:3128/"),
            ("http://LOCALHOST/", ""),
            ("http://localhost.example.com/", "http://proxy.local:3128/"),
            ("ftp://example.com/", ""),
        ],
    ),
    # NO_PROXY=* turns every host off; without it the upper-case name is read.
    ({"HTTP_PROXY": "http://upper:2", "NO_PROXY": "*"}, [("http://example.com/", "")]),
    ({"HTTP_PROXY": "http://upper:2"}, [("http://example.com/", "http://upper:2"), ("https://example.com/", "")]),
    # httpoxy: REQUEST_METHOD (a CGI program) makes HTTP_PROXY untrusted; the other names stay.
    (
        {"REQUEST_METHOD": "GET", "HTTP_PROXY": "http://evil:2", "HTTPS_PROXY": "http://ok:3"},
        [("http://example.com/", ""), ("https://example.com/", "http://ok:3")],
    ),
    # An entry that is not valid is ignored: none crashes the call, and none exempts a host (0.1 is not the tail of
    # 10.0.0.1).
    (
        {"http_proxy": "http://p:1", "NO_PROXY": "1.2.3.4/,a/,/,10.0.0.0/33,10.0.0.0/x,10.0.0.0/8/9,0.1,::1:80x"},
        [
            ("http://1.2.3.4/", "http://p:1"),
            ("http://a/", "http://p:1"),
            ("http://10.0.0.1/", "http://p:1"),
            ("http://[::1]/", "http://p:1"),
        ],
    ),
    # Spaces separate entries too; an entry with the default port, an IPv6 literal with a port, a trailing dot.
    (
        {"http_proxy": "http://p:1", "https_proxy": "http://s:2", "NO_PROXY": "a.com:80 [::1]:8080  example.net."},
        [
            ("http://a.com/", ""),
            ("https://a.com/", "http://s:2"),
            ("http://[::1]:8080/", ""),
            ("http://[::1]:9090/", "http://p:1"),
            ("http://example.net/", ""),
            ("http://example.net./", ""),
            ("http://www.example.net/", ""),
        ],
    ),
    ({"http_proxy": "http://p:1", "NO_PROXY": "example.com"}, [("http://example.com./", "")]),
    ({"http_proxy": "http://p:1", "NO_PROXY": "a.test  b.test,c.test"},
     [("http://a.test/", ""), ("http://b.test/", ""), ("http://c.test/", ""), ("http://d.test/", "http://p:1")]),
    # 0.0.0.0/0 is every IPv4 address and no name.
    (
        {"http_proxy": "http://p:1", "NO_PROXY": "0.0.0.0/0"},
        [("http://8.8.8.8/", ""), ("http://example.com/", "http://p:1")],
    ),
    # A lower-case http_proxy under CGI: trusted on POSIX, but Windows has no such name apart from HTTP_PROXY (a request
    # may have made it), so an http:// URL gets none there.
    (
        {"REQUEST_METHOD": "GET", "http_proxy": "http://x:1"},
        [("http://example.com/", "" if WINDOWS else "http://x:1")],
    ),
    # Another scheme is returned as it is.
    ({"http_proxy": "socks5://p:1080"}, [("http://example.com/", "socks5://p:1080")]),
]


# Two names of one variable that differ only by case: Windows has one variable for both, so these run on POSIX only.
ENV_CASES_BY_CASE = [
    # The lower-case name wins over the upper-case one, even when it is set and empty.
    (
        {"http_proxy": "http://lower:1", "HTTP_PROXY": "http://upper:2", "https_proxy": "",
         "HTTPS_PROXY": "http://up-secure:3", "no_proxy": "", "NO_PROXY": "*"},
        [("http://example.com/", "http://lower:1"), ("https://example.com/", "")],
    ),
    # A lower-case http_proxy is trusted under CGI; the upper-case one next to it is not.
    ({"REQUEST_METHOD": "GET", "HTTP_PROXY": "http://evil:2", "http_proxy": "http://mine:1"},
     [("http://example.com/", "http://mine:1")]),
]


def run_env_cases(tmp_path, cases):
    """One VM run of ENV_PROGRAM for each (environment, expectations) of `cases`."""
    source = tmp_path / "env.agc"
    source.write_text(ENV_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "env.agcb")
    for env, expected in cases:
        extra = {name: None for name in ENV_NAMES}
        extra.update(env)
        result = run_vm(bytecode, env=vm_environment(extra), args=[url for url, _ in expected], timeout=scaled(60))
        assert result.code == 0, result.stderr
        assert output_lines(result.stdout) == ["%s => [%s]" % pair for pair in expected], env


def test_proxy_from_env_reads_the_proxy_variables_the_way_curl_does(tmp_path):
    """Only a program that calls HTTP.proxy_from_env reads the environment: the variables, the httpoxy rule and each
    kind of no_proxy entry, over controlled environments (no peer is needed)."""
    run_env_cases(tmp_path, ENV_CASES)


@host_only(WINDOWS, "Windows has one environment variable for http_proxy and HTTP_PROXY: names do not differ by case")
def test_proxy_from_env_prefers_the_lower_case_names(tmp_path):
    """The lower-case name wins over the upper-case one, even empty, and is the only one trusted under CGI."""
    run_env_cases(tmp_path, ENV_CASES_BY_CASE)


ENV_CLIENT_PROGRAM = """\
import HTTP from "std/http"

def main() -> Void
  args = System.args()
  for url in ["http://127.0.0.1:#{args[0]}/hello", "http://127.0.0.1:#{args[1]}/hello"]
    options = HttpClientOptions(proxy: HTTP.proxy_from_env(url))
    case HTTP.get_response(url, options)
      ok(response) -> puts("#{response.status} via=#{HTTP.header_values(response.headers, "via")}")
      error(message) -> puts(message)
    end
  end
end
"""


def test_the_proxy_of_the_environment_is_the_proxy_option_of_a_client(tmp_path, adopt):
    """The value of proxy_from_env goes straight into HttpClientOptions: the origin that no_proxy names is reached
    directly, the other through the proxy."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    proxy, first, second, _proxy_two, _locked = peer.next_line().split()[:5]
    source = tmp_path / "env_client.agc"
    source.write_text(ENV_CLIENT_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "env_client.agcb")
    extra = {name: None for name in ENV_NAMES}
    extra.update(http_proxy="127.0.0.1:" + proxy, no_proxy="127.0.0.1:" + second)
    result = run_vm(bytecode, env=vm_environment(extra), args=[first, second], timeout=scaled(60))
    assert result.code == 0, result.stderr
    assert output_lines(result.stdout) == ['200 via=["1.1 proxy-peer"]', "200 via=[]"]
    # Only the first request reached the proxy.
    assert peer.next_line().split(" ", 2)[2] == "GET http://127.0.0.1:%s/hello HTTP/1.1 | 127.0.0.1:%s" % (first, first)


TUNNEL_PROGRAM = """\
import HTTP from "std/http"

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{Result.unwrap_or(String.from_bytes(response.body), "<not UTF-8>")}")
    error(message) -> puts(message)
  end
end

def chunks(into: Channel[Bytes]) -> Void
  into.send("0123456".bytes, 2000)
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

# Whether the call failed with the error that names the proxy that could not be reached (its text has more lines).
def names_down(r: Result[HttpResponse], gone: String) -> Bool
  case r
    ok(_) -> return false
    error(message) -> return String.starts_with?(message, "http: cannot reach the proxy #{gone}: ")
  end
end

def started(origin: String, options: HttpClientOptions, path: String) -> Void
  case HTTP.start(origin, options)
    ok(conn) ->
      case HTTP.send_request(conn, "GET", path, "".bytes)
        ok(head) -> puts("start #{head.status} #{String.from_bytes(HTTP.read_body(conn).unwrap!).unwrap!}")
        error(message) -> puts(message)
      end

      HTTP.finish(conn)
    error(message) -> puts(message)
  end
end

# Every call of the client over a tunnel to C or D, and the line it prints.
def calls(options: HttpClientOptions, c: String, d: String, dir: String, tag: String) -> Void
  pool = HTTP.client(options).unwrap!
  show(HTTP.get(pool, "#{c}/hello?#{tag}"))
  show(HTTP.get(pool, "#{c}/hello?#{tag}2"))
  show(HTTP.get(pool, "#{d}/hello?#{tag}"))
  HTTP.close_client(pool)
  show(HTTP.post_response("#{c}/echo", "abc".bytes, [], options))
  case HTTP.download(HTTP.client(options).unwrap!, "#{c}/big", "#{dir}/#{tag}.bin")
    ok(done) -> puts("download #{done.status} #{File.stat("#{dir}/#{tag}.bin").unwrap!.size_bytes}")
    error(message) -> puts(message)
  end

  case HTTP.open("GET", "#{c}/big", "".bytes, [], options)
    ok(stream) -> puts("open #{stream.status} #{count(stream)}")
    error(message) -> puts(message)
  end

  into: Channel[Bytes] = Channel.new(2)
  Task.spawn(&chunks, into)
  show(HTTP.upload("PUT", "#{c}/echo", into, -1, [], options))
  started(c, options, "/hello?#{tag}")
end

def main() -> Void
  args = System.args()
  proxy = "127.0.0.1:#{args[0]}"
  locked = "127.0.0.1:#{args[1]}"
  c = "https://127.0.0.1:#{args[2]}"
  d = "https://127.0.0.1:#{args[3]}"
  dir = args[4]
  context = TLS.client_context(TlsClientOptions(ca_file: args[5])).unwrap!
  calls(HttpClientOptions(proxy: "http://#{proxy}", tls: some(context)), c, d, dir, "ctx")
  calls(HttpClientOptions(proxy: "http://#{proxy}"), c, d, dir, "sys")
  puts("-- the locked proxy")
  login = "http://us%40er:p%3Ass%2Fw@#{locked}"
  show(HTTP.get_response("#{c}/hello?locked", HttpClientOptions(proxy: login, tls: some(context))))
  started(c, HttpClientOptions(proxy: login, tls: some(context)), "/hello?locked")
  show(HTTP.get_response("#{c}/hello?system", HttpClientOptions(proxy: login)))
  show(HTTP.get_response("#{c}/hello", HttpClientOptions(proxy: "http://#{locked}", tls: some(context))))
  started(c, HttpClientOptions(proxy: "http://#{locked}", tls: some(context)), "/hello")
  show(HTTP.get_response("#{c}/hello", HttpClientOptions(proxy: "http://us%40er:hunter2@#{locked}", tls: some(context))))
  puts("-- a 407 of the origin is a response, and no login reaches it")
  show(HTTP.get_response("#{c}/407", HttpClientOptions(proxy: login, tls: some(context))))
  show(HTTP.get_response("#{c}/seen", HttpClientOptions(tls: some(context))))
  puts("-- the target is verified inside the tunnel")
  strict = TLS.client_context(TlsClientOptions(ca_file: args[7])).unwrap!
  case HTTP.get_response("#{c}/hello", HttpClientOptions(proxy: "http://#{proxy}", tls: some(strict)))
    ok(_) -> puts("answered")
    error(message) -> puts(String.contains?(message, "proxy"))
  end

  puts("-- a refused tunnel, a proxy that is down, a bad proxy")
  refused = HttpClientOptions(proxy: "http://#{proxy}", tls: some(context))
  show(HTTP.get_response("https://127.0.0.1:9/", refused))
  started("https://127.0.0.1:9", refused, "/")
  down = HttpClientOptions(proxy: "http://127.0.0.1:#{args[6]}", tls: some(context))
  puts(names_down(HTTP.get_response("#{c}/hello", down), "127.0.0.1:#{args[6]}"))
  case HTTP.start(c, down)
    ok(_) -> puts("started")
    error(message) -> puts(String.starts_with?(message, "http: cannot reach the proxy 127.0.0.1:#{args[6]}: "))
  end

  show(HTTP.get_response("#{c}/hello", HttpClientOptions(proxy: "ftp://#{proxy}", tls: some(context))))
  puts("-- a proxy that stalls, and a 200 with junk after its head")
  stalled = HttpClientOptions(proxy: "http://#{proxy}", tls: some(context), timeout_ms: 500)
  show(HTTP.get_response("https://127.0.0.1:7/", stalled))
  show(HTTP.get_response("https://127.0.0.1:8/", refused))
  started("https://127.0.0.1:8", refused, "/")
end
"""


def test_https_goes_through_a_proxy_in_a_connect_tunnel(tmp_path, adopt):
    """An https request through a proxy is a CONNECT to the target's host:port, then TLS inside the tunnel against the
    target (on the context of tls, or the system trust), for every call: the pooled tunnel is one per target, the
    login goes with the CONNECT only and never to the target, a non-2xx answer is an error that names the proxy, and
    a 407 of the target itself is its response."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    proxy, _first, _second, _proxy_two, locked, tls_c, tls_d = peer.next_line().split()
    with socket.socket() as spare:
        spare.bind(("127.0.0.1", 0))
        down = str(spare.getsockname()[1])
    source = tmp_path / "tunnel.agc"
    source.write_text(TUNNEL_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "tunnel.agcb")
    ca = str(FIXTURES / "tls" / "ca.pem")
    env = vm_environment({"SSL_CERT_FILE": ca})
    result = run_vm(bytecode, env=env, args=[proxy, locked, tls_c, tls_d, str(tmp_path), ca, down, str(FIXTURES / "tls" / "self-signed.pem")], timeout=scaled(120))
    assert result.code == 0, result.stderr

    def served(tag):
        return [
            "200 hello from C /hello?%s" % tag,
            "200 hello from C /hello?%s2" % tag,
            "200 hello from D /hello?%s" % tag,
            "200 got 3 bytes: abc",
            "download 200 200000",
            "open 200 200000",
            "200 got 7 bytes: 0123456",
            "start 200 hello from C /hello?%s" % tag,
        ]

    name = "127.0.0.1:" + locked
    refused = "http: the proxy 127.0.0.1:%s refused the tunnel to 127.0.0.1:9 (403)" % proxy
    junk = ("http: the tunnel to 127.0.0.1:8 through the proxy 127.0.0.1:%s failed: "
            "network: data came before the TLS handshake" % proxy)
    lines = output_lines(result.stdout)
    assert lines == [
        *served("ctx"),
        *served("sys"),
        "-- the locked proxy",
        "200 hello from C /hello?locked",
        "start 200 hello from C /hello?locked",
        "200 hello from C /hello?system",
        "http: the proxy %s requires credentials (407): put user:password in the proxy URL" % name,
        "http: the proxy %s requires credentials (407): put user:password in the proxy URL" % name,
        "http: the proxy %s refused the credentials (407)" % name,
        "-- a 407 of the origin is a response, and no login reaches it",
        "407 the origin wants credentials",
        "200 seen []",
        "-- the target is verified inside the tunnel",
        "false",
        "-- a refused tunnel, a proxy that is down, a bad proxy",
        refused,
        refused,
        "true",
        "true",
        "http: the proxy must be http://host:8080 or http://user:pass@host:8080, with no path or query",
        "-- a proxy that stalls, and a 200 with junk after its head",
        "http: the tunnel to 127.0.0.1:7 through the proxy 127.0.0.1:%s failed: network: operation timed out" % proxy,
        junk,
        junk,
    ], lines
    # The CONNECT lines the peer saw, in order: the pooled client (one tunnel for the two gets of C, one for D), then a
    # tunnel for each of the other calls; and the same again on the system trust.
    seen = [peer.next_line().split(" ", 2)[2] for _ in range(14 + 7 + 1 + 2 + 3)]
    connect = "CONNECT 127.0.0.1:%s HTTP/1.1 | 127.0.0.1:%s"
    on_c, on_d = connect % (tls_c, tls_c), connect % (tls_d, tls_d)
    assert seen[:14] == [on_c, on_d, on_c, on_c, on_c, on_c, on_c] * 2, seen
    # The locked proxy: the login with the CONNECT of the good calls, none or a wrong one in the others.
    assert [line.rsplit(" | ", 1)[1] for line in seen[14:21]] == [LOGIN, LOGIN, LOGIN, "-", "-"] + [
        seen[19].rsplit(" | ", 1)[1], LOGIN], seen
    assert seen[19].rsplit(" | ", 1)[1].startswith("Basic ") and seen[19].rsplit(" | ", 1)[1] != LOGIN
    assert seen[21] == on_c, seen
    assert seen[22:] == [connect % ("9", "9")] * 2 + [connect % ("7", "7")] + [connect % ("8", "8")] * 2, seen
    everything = result.stdout + result.stderr
    for secret in ("hunter2", "p:ss", "p%3Ass", "ss/w", "us@er", "us%40er"):
        assert secret not in everything, secret
