"""The VM HTTP client through a forward proxy, against tests/fixtures/http-proxy-peer.py.

The peer is a proxy that accepts only the absolute-form request target and two origin servers, on 127.0.0.1 with port 0.
It prints a line for each request it sees, so the tests assert the request line and the Host header as the proxy got
them, and the connection they came on.
"""
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
  shown_error(HTTP.client(HttpClientOptions(proxy: "ftp://127.0.0.1:1")))
  shown_error(HTTP.client(HttpClientOptions(proxy: "http://user:pass@127.0.0.1:1")))
  shown_error(HTTP.client(HttpClientOptions(proxy: "http://127.0.0.1:1/path")))
  show(HTTP.get_response("#{a}/hello?direct"))
end
"""


def test_requests_go_to_the_proxy_in_absolute_form_on_one_pooled_connection(tmp_path, adopt):
    """Every call of the client reaches the proxy with the absolute-form target and the Host of the target: the pooled
    calls share one proxy connection even for two origins, a request to another name keeps its Host, and a call with
    no proxy does not touch it. https and a bad proxy are errors."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    proxy, first, second = peer.next_line().split()
    source = tmp_path / "proxy.agc"
    source.write_text(PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "proxy.agcb")
    result = run_vm(bytecode, env=vm_environment(), args=[proxy, first, second, str(tmp_path)], timeout=scaled(120))
    assert result.code == 0, result.stderr
    assert output_lines(result.stdout) == [
        '200 hello from A /hello via=["1.1 proxy-peer"]',
        '200 hello from B /hello?x=1 via=["1.1 proxy-peer"]',
        '200 got 4 bytes: ping via=["1.1 proxy-peer"]',
        "200",
        "200000",
        '200 hello from B /hello via=["1.1 proxy-peer"]',
        '200 got 3 bytes: abc via=["1.1 proxy-peer"]',
        "200 200000",
        '200 got 16 bytes: 0123456789 via=["1.1 proxy-peer"]',
        '200 ["1.1 proxy-peer"]',
        "hello from B /hello?start",
        "http: https through a proxy is not supported yet",
        "http: the proxy must be an http:// origin such as http://host:8080, with no user info, path or query",
        "http: the proxy must be an http:// origin such as http://host:8080, with no user info, path or query",
        "http: the proxy must be an http:// origin such as http://host:8080, with no user info, path or query",
        '200 hello from A /hello?direct via=[]',
    ]
    seen = [peer.next_line() for _ in range(9)]
    assert [line.split(" ", 2)[2] for line in seen] == [
        "GET http://127.0.0.1:%s/hello HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/hello?x=1 HTTP/1.1 | 127.0.0.1:%s" % (second, second),
        "POST http://localhost:%s/echo HTTP/1.1 | localhost:%s" % (first, first),
        "GET http://127.0.0.1:%s/big HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/hello HTTP/1.1 | 127.0.0.1:%s" % (second, second),
        "POST http://127.0.0.1:%s/echo HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "GET http://127.0.0.1:%s/big HTTP/1.1 | 127.0.0.1:%s" % (first, first),
        "PUT http://127.0.0.1:%s/echo HTTP/1.1 | 127.0.0.1:%s" % (second, second),
        "GET http://127.0.0.1:%s/hello?start HTTP/1.1 | 127.0.0.1:%s" % (second, second),
    ]
    # The first three requests (two origins and a second name) used the pool's one connection to the proxy.
    assert len({line.split(" ")[1] for line in seen[:3]}) == 1
